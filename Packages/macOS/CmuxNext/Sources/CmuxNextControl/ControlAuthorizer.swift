import Foundation
import CmuxNextSettings
import Darwin
import Synchronization

/// Per-connection authorization state, owned by the connection's task.
struct ControlAuthorizer: Sendable {
    let configuration: ControlSocketServer.Configuration
    let peer: ControlSocketServer.Peer
    var isPasswordAuthenticated = false

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
        if configuration.accessMode == .password {
            if loweredVerb == "auth" {
                return (loginV1(line), true)
            }
            if isJSON, case .success(let request) = ControlRouter.decode(line), request.method == "auth.login" {
                return (loginV2(request), true)
            }
            if !isPasswordAuthenticated {
                if isJSON {
                    let id = (try? JSONValue.parse(Data(line.utf8)))?["id"]
                    return (ControlRouter.encode(id: id, error: ControlError(code: "auth_required", message: ControlStrings.text("control.error.authRequired", "Authentication required. Send auth <password> first."))), true)
                }
                return ("ERROR: Authentication required — send auth <password> first", true)
            }
        } else if loweredVerb == "auth" {
            return ("OK: Authentication not required", true)
        } else if isJSON, case .success(let request) = ControlRouter.decode(line), request.method == "auth.login" {
            return (ControlRouter.encode(id: request.id, result: .success(["authenticated": true])), true)
        }
        return (await router.response(forLine: line, connection: connection), true)
    }

    /// The `events.stream` request in `rawLine`, when this connection may
    /// run it now (admitted, and authenticated in password mode).
    func eventStreamRequest(_ rawLine: String) -> ControlRequest? {
        let line = Self.unwrapEnvelopes(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        guard line.hasPrefix("{"), isPeerAdmitted, configuration.accessMode != .password || isPasswordAuthenticated,
              case .success(let request) = ControlRouter.decode(line), request.method == ControlRouter.eventStreamMethod else { return nil }
        return request
    }

    var isPeerAdmitted: Bool {
        switch configuration.accessMode {
        case .off:
            return false
        case .allowAll:
            return true
        case .automation, .password:
            return peer.uid == getuid()
        case .cmuxOnly:
            guard let pid = peer.pid else { return false }
            return Self.isProcess(pid, descendantOf: configuration.trustedAncestor)
        }
    }

    private mutating func loginV1(_ line: String) -> String {
        let provided = line.count > 5 ? String(line.dropFirst(5)) : ""
        guard !provided.isEmpty else { return "ERROR: Missing password. Usage: auth <password>" }
        guard configuration.passwordVerifier?(provided) == true else { return "ERROR: Invalid password" }
        isPasswordAuthenticated = true
        return "OK: Authenticated"
    }

    private mutating func loginV2(_ request: ControlRequest) -> String {
        guard let provided = request.params["password"]?.stringValue else {
            return ControlRouter.encode(id: request.id, error: .invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", "auth.login", "password")))
        }
        guard configuration.passwordVerifier?(provided) == true else {
            return ControlRouter.encode(id: request.id, error: ControlError(code: "auth_failed", message: ControlStrings.text("control.error.invalidPassword", "Invalid password")))
        }
        isPasswordAuthenticated = true
        return ControlRouter.encode(id: request.id, result: .success(["authenticated": true]))
    }

    /// Strips the CLI's optional line prefixes: the capability envelope
    /// (`_cmux_capability_v1 <token> `) and the automation origin
    /// (`__cmux_automation_origin <base64> `). cmux-next does not verify
    /// capabilities yet, so a capability never widens access.
    static func unwrapEnvelopes(_ line: String) -> String {
        var current = Substring(line)
        for prefix in ["_cmux_capability_v1 ", "__cmux_automation_origin "] where current.hasPrefix(prefix) {
            let rest = current.dropFirst(prefix.count)
            guard let space = rest.firstIndex(of: " ") else { return String(current) }
            current = rest[rest.index(after: space)...]
        }
        return String(current)
    }

    static func isProcess(_ pid: pid_t, descendantOf ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<128 {
            if current == ancestor { return true }
            if current <= 1 { return false }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            if parent == current || parent < 0 { return false }
            current = parent
        }
        return false
    }
}
