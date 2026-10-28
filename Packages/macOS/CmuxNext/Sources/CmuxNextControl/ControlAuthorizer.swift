import Foundation
import CmuxNextSettings
import Darwin
import CmuxNextCompat

/// Per-connection authorization state, owned by the connection's task.
struct ControlAuthorizer: Sendable {
    let configuration: ControlSocketServer.Configuration
    let peer: ControlSocketServer.Peer

    init(configuration: ControlSocketServer.Configuration, peer: ControlSocketServer.Peer) {
        self.configuration = configuration
        self.peer = peer
    }

    static let accessDenied = "ERROR: Access denied - only processes started inside cmux can connect"

    /// One request line after the peer policy, the envelopes, the auth handshake, the v1 `ping` and the
    /// JSON parse, which all answer without the router: also while the startup lock holds requests
    /// (``ControlStartupLock``, p08-startup-107).
    enum Screened: Sendable {
        /// Answered here (nil: an empty line, nothing to send); `keepOpen` false ends the connection.
        case answered(String?, keepOpen: Bool)
        /// A v2 request for the router.
        case request(ControlRequest)
        /// A v1 plain-text line for the router's v1 handler.
        case plainText(String)
    }

    /// Screens one request line: the peer policy first, then the envelopes, `auth`, the v1 `ping` and the
    /// JSON parse. Runs on the connection's task, never on the main thread.
    func screen(_ rawLine: String) -> Screened {
        let line = Self.unwrapEnvelopes(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return .answered(nil, keepOpen: true) }
        guard isPeerAdmitted else { return .answered(Self.accessDenied, keepOpen: false) }
        guard line.hasPrefix("{") else {
            switch line.split(separator: " ", maxSplits: 1).first?.lowercased() {
            case "auth": return .answered("OK: Authentication not required", keepOpen: true)
            case "ping": return .answered("PONG", keepOpen: true)
            default: return .plainText(line)
            }
        }
        switch ControlRouter.decode(line) {
        case .failure(let error):
            return .answered(ControlRouter.encode(id: nil, error: error), keepOpen: true)
        case .success(let request) where request.method == "auth.login":
            return .answered(ControlRouter.encode(id: request.id, result: .success(["authenticated": true])), keepOpen: true)
        case .success(let request):
            return .request(request)
        }
    }

    /// The response line for one request line on `router`, with no startup lock (in-process callers and
    /// tests), and whether to keep the connection open.
    func respond(to rawLine: String, router: ControlRouter, connection: ControlConnectionID = .inProcess) async -> (String?, Bool) {
        switch screen(rawLine) {
        case .answered(let response, let keepOpen):
            return (response, keepOpen)
        case .request(let request):
            return (ControlRouter.encode(id: request.id, result: await router.handle(request, connection: connection)), true)
        case .plainText(let text):
            return (await router.response(forLine: text, connection: connection), true)
        }
    }

    var isPeerAdmitted: Bool {
        switch configuration.accessMode {
        case .off:
            return false
        case .automation:
            return peer.uid == getuid()
        case .cmuxOnly:
            guard peer.uid == getuid(), let pid = peer.pid else { return false }
            return ControlPeerAncestry.system.isInside(pid, ancestor: configuration.trustedAncestor,
                                                       executables: configuration.trustedExecutables)
        }
    }

    /// Strips the CLI's optional line prefixes: the capability envelope
    /// (`_cmux_capability_v1 <token> `) and the automation origin
    /// (`__cmux_automation_origin <base64> `). cmux-next does not verify
    /// capabilities yet, so a capability never widens access.
    static func unwrapEnvelopes(_ line: String) -> String {
        var current = Substring(line)
        for prefix in ["_cmux_capability_v1 ", "__cmux_automation_origin "] where current.hasPrefix(prefix) {
            let rest = current.dropFirst(prefix.count)
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let after = parts.last else { return String(current) }
            current = after
        }
        return String(current)
    }
}
