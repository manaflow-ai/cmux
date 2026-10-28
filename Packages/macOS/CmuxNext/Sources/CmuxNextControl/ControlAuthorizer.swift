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

    /// The response line for one request line, and whether to keep the
    /// connection open.
    mutating func respond(to rawLine: String, router: ControlRouter, connection: ControlConnectionID = .inProcess) async -> (String?, Bool) {
        let line = Self.unwrapEnvelopes(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return (nil, true) }
        guard isPeerAdmitted else { return (Self.accessDenied, false) }

        let isJSON = line.hasPrefix("{")
        let loweredVerb = isJSON ? "" : line.split(separator: " ", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        if loweredVerb == "auth" {
            return ("OK: Authentication not required", true)
        } else if isJSON, case .success(let request) = ControlRouter.decode(line), request.method == "auth.login" {
            return (ControlRouter.encode(id: request.id, result: .success(["authenticated": true])), true)
        }
        return (await router.response(forLine: line, connection: connection), true)
    }

    /// The `events.stream` request in `rawLine`, when this connection is admitted.
    func eventStreamRequest(_ rawLine: String) -> ControlRequest? {
        let line = Self.unwrapEnvelopes(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        guard line.hasPrefix("{"), isPeerAdmitted,
              case .success(let request) = ControlRouter.decode(line), request.method == ControlRouter.eventStreamMethod else { return nil }
        return request
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
