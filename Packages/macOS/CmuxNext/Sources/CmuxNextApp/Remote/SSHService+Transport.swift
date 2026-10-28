import CmuxNextDaemon
import CmuxNextRemote
import Foundation

/// SSH's process environment and the session registry's transport fields (moved out of SSHService.swift).
extension SSHService {
    /// The environment ssh runs with: the app's own process identity (HOME,
    /// USER, SSH_AUTH_SOCK for the user's agent) plus the login shell's
    /// PATH for ProxyCommand helpers. Never a token or key.
    @Sendable static func environment() async -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        var env = await TerminalEnvironment.instance.shared(base: base)()
        for key in TerminalEnvironment.instance.daemonIdentityKeys { if let value = base[key] { env[key] = value } }
        return env
    }

    /// The registry transport for `session`.
    static func transport(_ session: SSHMachineSession) -> JSONValue {
        var fields = session.host.transportFields.mapValues(JSONValue.string)
        fields["connect"] = .string(session.autoConnect ? "true" : "false")
        return .object(fields)
    }

    static func fields(_ transport: JSONValue) -> [String: String]? {
        guard case .object(let object) = transport else { return nil }
        return object.compactMapValues { value in
            if case .string(let text) = value { return text }
            return nil
        }
    }
}
