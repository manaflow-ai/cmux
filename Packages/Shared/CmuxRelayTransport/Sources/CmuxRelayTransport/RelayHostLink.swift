// Host side of the relay: one outbound WebSocket serving every phone session.
// Each `peer_joined` becomes one CmxByteTransport handed to the session
// handler (the Mac funnels it into MobileHostService.acceptTransport, which
// owns RPC dispatch, per-request Stack auth, and event fan-out). When the
// handler returns, the link tells the relay to close that client's socket.

import CMUXMobileCore
import Foundation

public struct RelayClientSession: Sendable {
    public let sessionID: UInt32
    public let clientDeviceID: String
    public let transport: any CmxByteTransport
}

public actor RelayHostLink {
    public typealias SessionHandler = @Sendable (RelayClientSession) async -> Void

    /// Refresh the session this long before its deadline.
    private static let refreshLead: TimeInterval = 60 * 60
    private static let reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    private let hostDeviceID: String
    private let ticketProvider: any RelayTicketProviding
    private let relayURLOverride: URL?
    private let makeConnection: RelayConnectionFactory
    private let onClientSession: SessionHandler

    private var connection: (any RelayConnecting)?
    private var refreshTask: Task<Void, Never>?
    private var sessions: [UInt32: RelayByteQueue] = [:]
    private var sessionTasks: [UInt32: Task<Void, Never>] = [:]
    private var stopped = false

    public init(
        hostDeviceID: String,
        ticketProvider: any RelayTicketProviding,
        relayURLOverride: URL? = nil,
        makeConnection: @escaping RelayConnectionFactory = RelayConnection.factory(),
        onClientSession: @escaping SessionHandler
    ) {
        self.hostDeviceID = hostDeviceID
        self.ticketProvider = ticketProvider
        self.relayURLOverride = relayURLOverride
        self.makeConnection = makeConnection
        self.onClientSession = onClientSession
    }

    /// Connect-and-serve until `stop()` or task cancellation. Reconnects with
    /// bounded backoff; a working round resets the backoff ladder.
    public func run() async {
        var failureCount = 0
        while !stopped && !Task.isCancelled {
            do {
                let served = try await serveOnce()
                failureCount = served ? 0 : failureCount + 1
            } catch {
                failureCount += 1
            }
            guard !stopped && !Task.isCancelled else { break }
            let delay = Self.reconnectDelays[min(failureCount, Self.reconnectDelays.count - 1)]
            try? await Task.sleep(for: delay)
        }
    }

    public func stop() async {
        stopped = true
        await teardown()
    }

    /// Returns true when the connection served long enough to be considered
    /// healthy (welcome received and the event stream ran).
    private func serveOnce() async throws -> Bool {
        let grant = try await ticketProvider.mintTicket(
            hostDeviceID: hostDeviceID,
            deviceID: hostDeviceID,
            role: .host
        )
        let connection = makeConnection(relayURLOverride ?? grant.relayURL, grant.ticket)
        let welcome = try await connection.connect()
        self.connection = connection
        scheduleRefresh(deadline: Date(timeIntervalSince1970: welcome.deadline / 1000))

        let events = await connection.events()
        for await event in events {
            if stopped { break }
            await handle(event)
        }
        await teardown()
        return true
    }

    private func handle(_ event: RelayConnectionEvent) async {
        switch event {
        case .control(.peerJoined(let joined)):
            guard joined.sessionId > 0 else { return }
            startSession(sessionID: UInt32(joined.sessionId), clientDeviceID: joined.deviceId)
        case .control(.peerLeft(let left)):
            guard left.sessionId > 0 else { return }
            // Finish the inbound queue so the host-side owner sees EOF and
            // unwinds naturally; never cancel a handler mid-RPC.
            endSession(UInt32(left.sessionId), cancelHandler: false)
        case .control(.refreshAck(let ack)):
            scheduleRefresh(deadline: Date(timeIntervalSince1970: ack.deadline / 1000))
        case .control(.bye), .control(.welcome):
            break
        case .data(let frame):
            guard let (channel, data) = RelayFrameCodec.splitChannel(frame.payload),
                  channel == RelayProtocol.channelRPC else {
                return // Reserved channel; ignore in v1.
            }
            await sessions[frame.sessionID]?.yield(data)
        }
    }

    private func startSession(sessionID: UInt32, clientDeviceID: String) {
        endSession(sessionID) // A reused id would be a relay bug; fail safe.
        let queue = RelayByteQueue()
        sessions[sessionID] = queue
        let transport = RelayHostSessionTransport(
            sessionID: sessionID,
            inbound: queue,
            link: self
        )
        let session = RelayClientSession(
            sessionID: sessionID,
            clientDeviceID: clientDeviceID,
            transport: transport
        )
        let handler = onClientSession
        sessionTasks[sessionID] = Task { [weak self] in
            await handler(session)
            // The host-side owner is done with this client (RPC loop ended,
            // auth failed, quota): close the client's relay socket too.
            await self?.closeSession(sessionID)
        }
    }

    private func endSession(_ sessionID: UInt32, cancelHandler: Bool = true) {
        if let queue = sessions.removeValue(forKey: sessionID) {
            Task { await queue.finish() }
        }
        if let task = sessionTasks.removeValue(forKey: sessionID), cancelHandler {
            task.cancel()
        }
    }

    fileprivate func closeSession(_ sessionID: UInt32) async {
        guard sessions[sessionID] != nil || sessionTasks[sessionID] != nil else { return }
        endSession(sessionID)
        guard let connection else { return }
        let message = RelayCloseSession(sessionId: Int(sessionID))
        if let json = try? JSONEncoder().encode(message) {
            try? await connection.sendControl(json)
        }
    }

    fileprivate func sendToClient(sessionID: UInt32, data: Data) async throws {
        guard let connection else { throw RelayConnectionError.notConnected }
        try await connection.sendData(
            sessionID: sessionID,
            payload: RelayFrameCodec.channelPayload(channel: RelayProtocol.channelRPC, data: data)
        )
    }

    private func scheduleRefresh(deadline: Date) {
        refreshTask?.cancel()
        let wait = deadline.timeIntervalSinceNow - Self.refreshLead
        guard wait > 0 else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard let connection else { return }
        do {
            let grant = try await ticketProvider.mintTicket(
                hostDeviceID: hostDeviceID,
                deviceID: hostDeviceID,
                role: .host
            )
            try await connection.sendControl(JSONEncoder().encode(RelayRefresh(ticket: grant.ticket)))
        } catch {
            // Best effort; the deadline close triggers a normal reconnect.
        }
    }

    private func teardown() async {
        refreshTask?.cancel()
        refreshTask = nil
        for sessionID in Array(sessions.keys) {
            endSession(sessionID)
        }
        await connection?.close()
        connection = nil
    }
}

/// One phone session as seen by the host: bytes in from the relay stream,
/// bytes out stamped with this session's id.
final class RelayHostSessionTransport: CmxByteTransport {
    private let sessionID: UInt32
    private let inbound: RelayByteQueue
    // Strong on purpose: the cycle link -> session task -> handler ->
    // transport -> link is broken when endSession releases the task.
    private let link: RelayHostLink

    init(sessionID: UInt32, inbound: RelayByteQueue, link: RelayHostLink) {
        self.sessionID = sessionID
        self.inbound = inbound
        self.link = link
    }

    func connect() async throws {
        // Already connected: the session exists because the relay announced it.
    }

    func receive() async throws -> Data? {
        await inbound.next()
    }

    func send(_ data: Data) async throws {
        try await link.sendToClient(sessionID: sessionID, data: data)
    }

    func close() async {
        await link.closeSession(sessionID)
    }
}
