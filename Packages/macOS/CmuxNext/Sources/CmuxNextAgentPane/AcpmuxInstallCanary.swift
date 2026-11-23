import Foundation
import Network

/// The canary chat connection of cmux NEXT NIGHTLY's install check (RFD 0028, item 6). After an
/// update installs, the updater asks whether a chat can still open on this build: the page's
/// `initialize` goes through the relay's own frame check (the one that refused every chat after
/// cmux#46563, 737 times, `transport.intent_invalid`), then to the acpmux daemon this build runs,
/// on a fresh connection. The decision on the result is Rust (cmux-install-check).
public nonisolated struct AcpmuxInstallCanary {
    public nonisolated init() {}
    /// What the hello found.
    public enum Outcome: Equatable, Sendable {
        /// The relay took the hello and the daemon answered it.
        case passed
        /// The relay or the daemon refused the hello; the refusal as a chat would see it.
        case refused(String)
        /// No answer either way: no daemon, a closed connection or the deadline.
        case inconclusive(String)
    }

    /// The page's `initialize` params, as `schemas/agent-pane/initialize-params.json` holds them
    /// (`AcpmuxInstallCanaryTests` keeps the two equal; the webviews contract test holds the page
    /// to the same file).
    static let pageInitializeParams: [String: any Sendable] = [
        "protocolVersion": 1,
        "clientInfo": ["name": "cmux-react-agent-pane", "version": "1"],
        "clientCapabilities": [String: any Sendable](),
        "_meta": ["acpmux": ["peerRowBatches": true]],
    ]

    /// The page's first frame, as text.
    static var pageInitialize: String {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": pageInitializeParams]
        let data = (try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The relay's refusal of the page's first frame, else nil: the same off-main rules every chat
    /// pane's first frame passes (``AgentPaneTransport/checkOne(_:_:)``).
    static func relayRefusal() -> String? {
        let snapshot = AgentPaneTransport.Snapshot(isFirst: true, localAppToken: nil, socketPath: nil, modeFields: nil,
                                                   sessions: AcpmuxPaneSessions(), options: AcpmuxPermissionOptions())
        switch AgentPaneTransport.checkOne(pageInitialize, snapshot) {
        case .frame: return nil
        case .refuse(.refuse(let error, _, _, let detail), _): return detail.map { "\(error.rawValue): \($0)" } ?? error.rawValue
        case .refuse(.send, _): return nil
        }
    }

    /// The canary against the daemon at `socketPath`: the relay's check, then the hello.
    @concurrent public static func run(socketPath: String, deadline: Duration = .seconds(20)) async -> Outcome {
        if let refusal = relayRefusal() { return .refused(refusal) }
        let connection: NWConnection
        do {
            connection = NWConnection(to: try AcpmuxStatusClient.unixEndpoint(socketPath), using: .tcp)
        } catch {
            return .inconclusive(String(describing: error))
        }
        defer { connection.cancel() }
        let transport = AcpmuxSocketTransport(connection: connection)
        do {
            return try await withAgentPaneDeadline(deadline, label: "acpmux install canary", onTimeout: { connection.cancel() }) {
                try await hello(on: transport)
            }
        } catch {
            return .inconclusive(String(describing: error))
        }
    }

    /// Sends the page's hello on `transport` and reads the reply to it. A JSON-RPC error is a
    /// refusal; a close before any reply says nothing (a daemon that exits for a version handoff).
    static func hello(on transport: any AcpmuxRPCTransport) async throws -> Outcome {
        try await transport.start()
        try await transport.send(Data(pageInitialize.utf8) + Data([0x0A]))
        var buffer = Data()
        while true {  // wakeup-allow: each pass awaits socket data; EOF, error or the deadline ends it
            guard let chunk = try await transport.receive() else { return .inconclusive("closed before the reply") }
            buffer += chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                do {
                    if try AcpmuxStatusClient.detailedReply(to: 1, in: line) != nil { return .passed }
                } catch let refusal as AcpmuxRPCError {
                    return .refused(refusal.name.map { "\($0): \(refusal.message)" } ?? refusal.message)
                }
            }
            if buffer.count > 1 << 20 { return .inconclusive("reply too large") }
        }
    }
}
