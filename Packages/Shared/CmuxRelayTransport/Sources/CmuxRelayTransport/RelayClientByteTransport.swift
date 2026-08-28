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
    /// Connect-lifecycle diagnostics sink (the iOS composition wires this to
    /// the in-app debug log so a failed dial is copyable from the phone).
    private let log: @Sendable (String) -> Void

    private var connection: (any RelayConnecting)?
    private var pumpTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var inbound: RelayByteQueue?

    public init(
        relayURLOverride: URL? = nil,
        hostDeviceID: String,
        deviceID: @escaping @Sendable () async throws -> String,
        accessToken: @escaping RelayAccessTokenProvider,
        makeConnection: @escaping RelayConnectionFactory = RelayConnection.factory(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.relayURLOverride = relayURLOverride
        self.hostDeviceID = hostDeviceID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.makeConnection = makeConnection
        self.log = log
    }

    public func connect() async throws {
        let ownDeviceID: String
        do {
            ownDeviceID = try await deviceID()
        } catch {
            log("relay.device_id_failed \(String(describing: error))")
            throw error
        }
        let token: String
        do {
            token = try await accessToken()
        } catch {
            log("relay.token_failed \(String(describing: error))")
            throw error
        }
        guard let url = relayURLOverride ?? RelayConnectAuth.defaultRelayURL() else {
            log("relay.dial_failed no relay URL")
            throw RelayTransportError.invalidRequest("no relay URL")
        }
        log("relay.dial url=\(url.absoluteString) host=\(hostDeviceID) device=\(ownDeviceID)")
        let connection = makeConnection(url, RelayConnectAuth.headers(
            accessToken: token,
            role: .client,
            hostDeviceID: hostDeviceID,
            deviceID: ownDeviceID
        ))
        let welcome: RelayWelcome
        do {
            welcome = try await connection.connect()
        } catch {
            // The URLError text names the exact failure class (cannot find
            // host, timed out, TLS, refused upgrade), which is the one fact
            // every blind "not connected" report has been missing.
            log("relay.ws_failed \(String(describing: error))")
            throw error
        }
        log("relay.welcome v=\(welcome.v) hostPresent=\(welcome.hostPresent) session=\(welcome.sessionId)")
        guard welcome.hostPresent else {
            await connection.close()
            log("relay.host_absent the Mac is not connected to its relay object")
            throw RelayTransportError.hostNotConnected
        }
        self.connection = connection

        // End-to-end admission, guaranteed first on the stream because it is
        // written before this transport is handed to the RPC session. Fire
        // and forget: a rejected admission ends with the host closing the
        // session (EOF here), which drives the normal repair path.
        do {
            try await connection.sendData(
                sessionID: RelayProtocol.hostSessionID,
                payload: RelayFrameCodec.channelPayload(
                    channel: RelayProtocol.channelRPC,
                    data: try RelayAdmission.admitFrame(accessToken: token, deviceID: ownDeviceID)
                )
            )
        } catch {
            log("relay.admit_send_failed \(String(describing: error))")
            throw error
        }
        log("relay.admit_sent")

        let queue = RelayByteQueue()
        inbound = queue

        let events = await connection.events()
        pumpTask = Task { [weak self, log] in
            for await event in events {
                guard let self else { return }
                let open = await self.handle(event, queue: queue)
                if !open { break }
            }
            log("relay.stream_ended")
            await queue.finish()
        }
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
            log("relay.host_left session ends (host disconnected from its relay object)")
            return false
        case .control(.bye):
            log("relay.bye relay closed the session")
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
