// Client (phone) side of the relay: one CmxByteTransport over one WebSocket.
// The RPC control stream rides CHANNEL_RPC data frames; events arrive as
// ordinary frames on that stream (no independent event lane), and terminal
// output rides the capability-negotiated render-grid / terminal.bytes topics,
// exactly like the legacy TCP path. Raw terminal channels are a reserved
// follow-up (RelayProtocol.channelTerminal).
//
// v2 connect: the transport dials with the endpoint's own Stack access token
// (the worker verifies it), then writes the end-to-end admission request as
// the FIRST bytes on the RPC stream, so the host binds this session to the
// account before any other request can arrive. Requests after admission
// carry no credentials at all.

import CMUXMobileCore
import Foundation

public enum RelayTransportError: Error, Equatable, Sendable {
    /// The relay accepted us but the host is not connected to its object.
    case hostNotConnected
    /// The factory request lacked the peer device id or a usable URL.
    case invalidRequest(String)
}

public actor RelayClientByteTransport: CmxByteTransport {
    /// Refresh the session this long before its deadline.
    private static let refreshLead: TimeInterval = 10 * 60

    /// Debug-only dial override; nil dials the production relay URL, so a
    /// shipped client needs no configuration.
    private let relayURLOverride: URL?
    private let hostDeviceID: String
    private let deviceID: @Sendable () async throws -> String
    private let accessToken: RelayAccessTokenProvider
    private let makeConnection: RelayConnectionFactory

    private var connection: (any RelayConnecting)?
    private var pumpTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var inbound: RelayByteQueue?

    public init(
        relayURLOverride: URL? = nil,
        hostDeviceID: String,
        deviceID: @escaping @Sendable () async throws -> String,
        accessToken: @escaping RelayAccessTokenProvider,
        makeConnection: @escaping RelayConnectionFactory = RelayConnection.factory()
    ) {
        self.relayURLOverride = relayURLOverride
        self.hostDeviceID = hostDeviceID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.makeConnection = makeConnection
    }

    public func connect() async throws {
        // A reconnect replaces the prior socket and pump. Without this,
        // repeated lifecycle callbacks leak a live WebSocket and duplicate
        // admissions onto the same RPC session.
        if connection != nil || pumpTask != nil || inbound != nil {
            await close()
        }
        let ownDeviceID = try await deviceID()
        let token = try await accessToken()
        guard let url = relayURLOverride ?? RelayConnectAuth.defaultRelayURL() else {
            throw RelayTransportError.invalidRequest("no relay URL")
        }
        let connection = makeConnection(url, RelayConnectAuth.headers(
            accessToken: token,
            role: .client,
            hostDeviceID: hostDeviceID,
            deviceID: ownDeviceID
        ))
        let welcome = try await connection.connect()
        guard welcome.hostPresent else {
            await connection.close()
            throw RelayTransportError.hostNotConnected
        }
        self.connection = connection

        let queue = RelayByteQueue()
        inbound = queue
        let events = await connection.events()
        pumpTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                let open = await self.handle(event, queue: queue)
                if !open { break }
            }
            await queue.finish()
        }

        // End-to-end admission, guaranteed first on the stream because it is
        // written before this transport is handed to the RPC session. Fire
        // and forget: a rejected admission ends with the host closing the
        // session (EOF here), which drives the normal repair path.
        try await connection.sendData(
            sessionID: RelayProtocol.hostSessionID,
            payload: RelayFrameCodec.channelPayload(
                channel: RelayProtocol.channelRPC,
                data: try RelayAdmission.admitFrame(accessToken: token, deviceID: ownDeviceID)
            )
        )
        scheduleRefresh(deadline: Date(timeIntervalSince1970: welcome.deadline / 1000))
    }

    public func receive() async throws -> Data? {
        guard let inbound else { return nil }
        return await inbound.next()
    }

    public func send(_ data: Data) async throws {
        guard let connection else { throw RelayConnectionError.notConnected }
        try await connection.sendData(
            sessionID: RelayProtocol.hostSessionID,
            payload: RelayFrameCodec.channelPayload(channel: RelayProtocol.channelRPC, data: data)
        )
    }

    public func close() async {
        refreshTask?.cancel()
        refreshTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        await connection?.close()
        connection = nil
        await inbound?.finish()
    }

    /// Returns false when the session is over and the pump should stop.
    private func handle(_ event: RelayConnectionEvent, queue: RelayByteQueue) async -> Bool {
        switch event {
        case .data(let frame):
            guard let (channel, data) = RelayFrameCodec.splitChannel(frame.payload),
                  channel == RelayProtocol.channelRPC else {
                return true // Reserved channel; ignore in v2.
            }
            await queue.yield(data)
            return true
        case .control(.peerLeft(let left)) where UInt32(left.sessionId) == RelayProtocol.hostSessionID:
            // The host disconnected from the relay: surface EOF so the RPC
            // session tears down and its owner redials/repairs with cursors.
            return false
        case .control(.bye):
            return false
        case .control(.refreshAck(let ack)):
            scheduleRefresh(deadline: Date(timeIntervalSince1970: ack.deadline / 1000))
            return true
        case .control:
            return true
        }
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
            let token = try await accessToken()
            try await connection.sendControl(JSONEncoder().encode(RelayRefresh(accessToken: token)))
        } catch {
            // Refresh is best effort; the deadline close surfaces as EOF and
            // the owner redials.
        }
    }
}
