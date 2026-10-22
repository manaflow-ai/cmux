import CmuxNextDaemon
import CmuxNextRemote
import Foundation

/// Why a chat's machine could not be reached, as the person can fix it (Leo 2026-10-21: a Mac
/// mini that was off read "acpmux did not answer in time", the same as a slow agent). Each way
/// of not reaching the machine is its own ``AgentRemoteStartRefusal`` code under
/// ``unreachedPrefix``; its sentence names the machine and what to fix.
extension AgentRemoteStartRefusal {
    /// The prefix of every unreached code (`agent_session.unreached.<kind>`).
    static let unreachedPrefix = "agent_session.unreached."
    /// The chat's machine refused a prompt because its disk is full (acpmux `storage.full`).
    static let storageFullCode = "agent_session.storage_full"

    /// `error` as an unreached refusal of `machine`: a dial refused before it got there (`cmux
    /// host dial`'s `error_code`), an ssh that could not connect, or a dropped connection. Nil
    /// for an answer from the machine itself (a refusal, an auth failure).
    static func unreached(_ error: any Error, machine: String) -> Self? {
        let kind: String
        var detail: String?
        switch error {
        case let error as DaemonError:
            if let code = DaemonBridge.refusalCode(error) {
                guard let dialed = dialKinds[code] else { return nil }
                kind = dialed
            } else {
                switch error {
                case .timedOut: kind = "no_answer"
                case .notConnected, .connectionClosed, .daemonShutdown, .connectFailed: kind = "lost"
                default: return nil
                }
            }
        case let error as SSHLinkError:
            guard case .ssh(let failure) = error, let ssh = sshKind(failure) else { return nil }
            kind = ssh.kind
            detail = ssh.detail
        case let failure as SSHFailure:
            guard let ssh = sshKind(failure) else { return nil }
            kind = ssh.kind
            detail = ssh.detail
        default:
            return nil
        }
        return Self(code: unreachedPrefix + kind, machine: machine, detail: detail)
    }

    /// `cmux host dial`'s `error_code`s (cmux-tui `remote_host/reach.rs`) and their kinds.
    private static let dialKinds: [String: String] = [
        "tailscale_off": "tailscale_off", "tailscale_missing": "tailscale_missing",
        "not_on_tailnet": "name", "host_offline": "offline", "not_serving": "not_serving",
        "no_answer": "no_answer", "not_yours": "not_yours", "unreachable": "other",
    ]

    /// An ssh that did not reach the machine, by OpenSSH's own words; nil for any other failure.
    private static func sshKind(_ failure: SSHFailure) -> (kind: String, detail: String?)? {
        guard failure.kind == .unreachable else { return nil }
        let text = failure.message
        func has(_ needles: [String]) -> Bool { needles.contains { text.localizedCaseInsensitiveContains($0) } }
        if has(["Could not resolve hostname", "Name or service not known", "Temporary failure in name resolution",
                "nodename nor servname"]) { return ("name", nil) }
        if has(["Connection refused"]) { return ("remote_login_off", nil) }
        if has(["timed out", "did not answer"]) { return ("no_answer", nil) }
        if has(["No route to host", "Host is down", "Network is unreachable"]) { return ("offline", nil) }
        if has(["Connection closed by", "Connection reset", "Broken pipe", "kex_exchange_identification"]) { return ("lost", nil) }
        return ("other", text)
    }

    /// The sentence of an unreached code or of a full disk; nil for any other code.
    var unreachedDescription: String? {
        switch code {
        case Self.unreachedPrefix + "tailscale_off":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.tailscaleOff",
                                  "Tailscale is off on this Mac, so cmux cannot reach %@. Turn Tailscale on, then try again.", machine)
        case Self.unreachedPrefix + "tailscale_missing":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.tailscaleMissing",
                                  "Tailscale is not installed on this Mac, so cmux cannot reach %@. Install Tailscale and sign in.", machine)
        case Self.unreachedPrefix + "name":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.name",
                                  "cmux cannot find %1$@ on your network. Turn Tailscale on, on this Mac and on %1$@, and sign both in to the same tailnet.", machine)
        case Self.unreachedPrefix + "offline":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.offline",
                                  "%1$@ is offline. Wake %1$@, and check that Tailscale is on there.", machine)
        case Self.unreachedPrefix + "remote_login_off":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.remoteLoginOff",
                                  "%1$@ is on, but it refuses connections. On %1$@, turn on Remote Login in System Settings > General > Sharing.", machine)
        case Self.unreachedPrefix + "not_serving":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.notServing",
                                  "%1$@ is on, but cmux does not serve there. Run cmux host enable on %1$@.", machine)
        case Self.unreachedPrefix + "no_answer":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.noAnswer",
                                  "%1$@ does not answer. Check that %1$@ is on and awake, and that Tailscale is on, on this Mac and on %1$@.", machine)
        case Self.unreachedPrefix + "not_yours":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.notYours",
                                  "%@ belongs to another person on your tailnet, so cmux does not connect to it.", machine)
        case Self.unreachedPrefix + "lost":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.lost",
                                  "The connection to %@ dropped. cmux connects again when it answers.", machine)
        case Self.unreachedPrefix + "other":
            RefusalStrings.format("handlers.refusal.agentRemote.unreached.other",
                                  "cmux cannot reach %1$@: %2$@", machine, detail ?? "")
        case Self.storageFullCode:
            RefusalStrings.format("handlers.refusal.agentRemote.storageFull",
                                  "The disk on %@ is full, so it cannot save this chat. Free some space there, then send again.", machine)
        default:
            nil
        }
    }
}
