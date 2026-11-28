import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "agent-pane-web")

/// The phone's host for the Mac's React agent pane (`webviews/src/agent-session/acpmux`, the bundled
/// `pane.js`): the same page the Mac shows, against the same acpmux daemon, reached through this
/// phone's link instead of the Mac's loopback socket.
///
/// The page speaks the Mac host's versioned bridge (`AgentPaneHandshake`, `bridgeSocket.ts`): it asks
/// `ready` for the handshake, then `transport.open`, `transport.send` and `transport.close`, and the
/// host pushes the daemon's frames to `window.cmuxAcpmuxTransport.receive(event)`. Here a connection
/// is one `acpmux` channel on the Mac link, so the page's JSON-RPC frames reach acpmux unchanged and
/// acpmux's replies and notifications come back as the page's frames. The page never sees an endpoint
/// or a token, as on the Mac. Every other native method (tabs, dictation, git writes) is refused with
/// `native.unsupported`, which the pane already shows as it does in the dev slot.
@MainActor
public final class AgentPaneWebBridge {
    /// The handshake version the bundled pane expects (`AgentPaneHandshake.currentVersion`).
    public static let protocolVersion = 2
    /// Methods this host answers; the rest are `native.unsupported`.
    public static let methods: Set<String> = ["ready", "transport.open", "transport.send", "transport.close", "transport.ack"]

    /// Opens a fresh `acpmux` channel on the Mac link (one per page connection).
    public typealias OpenChannel = @MainActor () async throws -> any LinkChannel
    /// Runs one script in the page (the push of `window.cmuxAcpmuxTransport.receive`).
    public typealias Evaluate = @MainActor (String) -> Void

    public let sessionID: String?
    public let machineName: String?
    private let openChannel: OpenChannel
    private let evaluate: Evaluate

    private final class Connection {
        let channel: any LinkChannel
        var reader: Task<Void, Never>?
        var seq = 0
        let opened = ContinuousClock.now
        init(channel: any LinkChannel) { self.channel = channel }
    }

    private var connections: [Int: Connection] = [:]
    private var nextConnection = 1

    public init(sessionID: String?, machineName: String?, openChannel: @escaping OpenChannel, evaluate: @escaping Evaluate) {
        self.sessionID = sessionID
        self.machineName = machineName
        self.openChannel = openChannel
        self.evaluate = evaluate
    }

    /// The page's open connections (tests, diagnostics).
    public var openConnections: Int { connections.count }

    /// The handshake the page reads on `ready` (field names of the TypeScript `AcpmuxHostConfig`).
    public var handshake: [String: Any] {
        var value: [String: Any] = ["protocolVersion": Self.protocolVersion, "transport": "acpmux-bridge", "surface": "phone"]
        // A chat opened from its row must be that chat, not the most recent one.
        if let sessionID { value["sessionId"] = sessionID; value["sessionMustExist"] = true }
        if let machineName { value["machineName"] = machineName }
        return value
    }

    /// Answers one `agentSession` message body (`{id, method, params}`) as the Mac's bridge does:
    /// `{ok: true, value}` or `{ok: false, error: {code, message}}`.
    public func handle(_ body: Any) async -> [String: Any] {
        guard let body = body as? [String: Any], let method = body["method"] as? String else {
            return Self.failure("native.bad_request", "The page sent a message without a method.")
        }
        let params = body["params"] as? [String: Any] ?? [:]
        switch method {
        case "ready":
            return Self.success(handshake)
        case "transport.open":
            do {
                let channel = try await openChannel()
                let id = nextConnection
                nextConnection += 1
                let connection = Connection(channel: channel)
                connections[id] = connection
                connection.reader = Task { [weak self] in await self?.read(id, channel) }
                log.info("agent pane: transport.open connection \(id, privacy: .public) on acpmux")
                return Self.success(["connection": id])
            } catch {
                log.error("agent pane transport.open failed: \(String(describing: error), privacy: .public)")
                return Self.failure("transport.open_failed", "Couldn't reach acpmux on the Mac.")
            }
        case "transport.send":
            guard let id = Self.int(params["connection"]), let connection = connections[id] else {
                return Self.failure("transport.stale_connection", "That connection is closed.")
            }
            let frames = params["frames"] as? [String] ?? []
            do {
                for frame in frames { try await connection.channel.send(Data(frame.utf8)) }
                return Self.success()
            } catch {
                close(id, code: "transport.closed", reason: String(describing: error))
                return Self.failure("transport.closed", "The Mac link closed.")
            }
        case "transport.close":
            if let id = Self.int(params["connection"]), let connection = connections.removeValue(forKey: id) {
                connection.reader?.cancel()
                Task { await connection.channel.close(code: "closed", reason: "page closed") }
            }
            return Self.success()
        case "transport.ack":
            // The page applied a push. The link has its own flow control, so nothing waits on it.
            return Self.success()
        default:
            return Self.failure("native.unsupported", "Not available on iPhone yet.")
        }
    }

    /// Closes every connection (the view went away).
    public func closeAll() {
        for id in Array(connections.keys) { close(id, code: "transport.closed", reason: "host closed", push: false) }
    }

    private func read(_ id: Int, _ channel: any LinkChannel) async {
        var joiner = AcpmuxConnection.MessageJoiner(zstd: AcpmuxConnection.MessageJoiner.makeZstd())
        do {
            while !Task.isCancelled, let data = try await channel.receive() {
                guard let value = joiner.push(data) else {
                    if joiner.streamLost { break }
                    continue
                }
                guard let text = String(data: try JSONEncoder().encode(value), encoding: .utf8) else { continue }
                push(id, frames: [text])
            }
            close(id, code: "transport.closed", reason: channel.closedBy?.message ?? "acpmux channel closed")
        } catch {
            close(id, code: "transport.closed", reason: String(describing: error))
        }
    }

    private func push(_ id: Int, frames: [String]) {
        guard let connection = connections[id] else { return }
        connection.seq += 1
        if connection.seq == 1 {
            let ms = Int((ContinuousClock.now - connection.opened) / .milliseconds(1))
            log.info("agent pane: first acpmux frame on connection \(id, privacy: .public) after \(ms, privacy: .public) ms")
        }
        evaluate(Self.receiveScript(["connection": id, "frames": frames, "seq": connection.seq]))
    }

    private func close(_ id: Int, code: String, reason: String, push: Bool = true) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.reader?.cancel()
        Task { await connection.channel.close(code: "closed", reason: reason) }
        if push {
            evaluate(Self.receiveScript(["connection": id, "closed": ["code": 1006, "reason": reason, "error": code]]))
        }
    }

    /// `window.cmuxAcpmuxTransport?.receive(event)`, as the Mac's ``AgentPaneTransport`` pushes it.
    public static func receiveScript(_ event: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.cmuxAcpmuxTransport?.receive(\(json));"
    }

    static func success(_ value: Any = [String: Any]()) -> [String: Any] { ["ok": true, "value": value] }

    static func failure(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
