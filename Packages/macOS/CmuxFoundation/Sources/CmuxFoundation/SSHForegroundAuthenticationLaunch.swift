internal import CryptoKit
internal import Foundation

/// Hands a workspace's SSH foreground-authentication token to the local launch
/// scripts that report `workspace.remote.foreground_auth_ready`.
///
/// The token travels in the launch process's environment and reaches the
/// cmux CLI on stdin, so it never appears in a process's arguments, where
/// any local user could read it with `ps`. It authorizes a local socket call
/// only and is never sent to the remote host.
public struct SSHForegroundAuthenticationLaunch: Sendable {
    /// Environment variable that carries the token into a launch script.
    public static let environmentKey = "CMUX_SSH_FOREGROUND_AUTH_TOKEN"

    /// Token the app expects in the readiness report.
    public let token: String

    /// Creates a launch for one foreground-authentication token.
    ///
    /// - Parameter token: Token from the workspace's remote configuration.
    public init(token: String) {
        self.token = token
    }

    /// Environment the local process that runs the launch script must receive.
    public var environment: [String: String] {
        [Self.environmentKey: token]
    }

    /// Marker a launch script carries so the app passes the token only to a
    /// command built for it. The marker is a digest and does not reveal the
    /// token.
    public var commandMarker: String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return "cmux-ssh-foreground-auth-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `command` was built by ``tokenLoadShellLines(into:)`` for this
    /// token, so its process should receive ``environment``.
    ///
    /// - Parameter command: Startup command of the process about to launch.
    public func isExpected(by command: String) -> Bool {
        command.contains(Self.environmentKey) && command.contains(commandMarker)
    }

    /// Shell lines that move the token from the environment into a shell
    /// variable, so commands the script runs later, such as `ssh`, do not
    /// inherit it.
    ///
    /// - Parameter variable: Shell variable that receives the token.
    public func tokenLoadShellLines(into variable: String) -> [String] {
        [
            ": \(commandMarker);",
            "\(variable)=\"${\(Self.environmentKey):-}\";",
            "unset \(Self.environmentKey);",
        ]
    }

    /// Environment assignment that passes the token in `variable` to one
    /// nested command, for use as a prefix on that command.
    ///
    /// - Parameter variable: Shell variable that holds the token.
    public static func environmentAssignment(from variable: String) -> String {
        "\(environmentKey)=\"$\(variable)\""
    }

    /// Shell lines that report foreground-authentication readiness to the
    /// local cmux socket and then clear the token variable.
    ///
    /// The JSON payload goes to `cmux rpc` on stdin. An empty token variable
    /// skips the report and is treated like a failed report. Each line ends
    /// with `;` or a shell keyword, so callers may join the lines with
    /// newlines or spaces.
    ///
    /// - Parameters:
    ///   - tokenVariable: Shell variable that holds the token.
    ///   - payloadVariable: Scratch shell variable for the JSON payload.
    ///   - cliVariable: Shell variable that holds the local cmux CLI path.
    ///   - socketVariable: Shell variable that holds the local socket path.
    ///   - controlPathVariable: Shell variable that holds the resolved
    ///     ControlMaster path, or `nil` to omit it from the payload.
    ///   - requireSuccess: Whether a failed report exits the script with 255.
    public static func readyShellLines(
        tokenVariable: String,
        payloadVariable: String,
        cliVariable: String,
        socketVariable: String,
        controlPathVariable: String? = nil,
        requireSuccess: Bool
    ) -> [String] {
        let controlPathField = controlPathVariable.map {
            ",\\\"control_path\\\":\\\"$\($0)\\\""
        } ?? ""
        let failureHandling = requireSuccess ? " || exit 255;" : " || true;"
        return [
            "if [ -n \"${\(tokenVariable):-}\" ]; then",
            "\(payloadVariable)=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\"," +
                "\\\"foreground_auth_token\\\":\\\"$\(tokenVariable)\\\"\(controlPathField)}\";",
            "printf '%s' \"$\(payloadVariable)\" | \"$\(cliVariable)\" --socket \"$\(socketVariable)\" rpc " +
                "workspace.remote.foreground_auth_ready - >/dev/null 2>&1" + failureHandling,
            "unset \(payloadVariable);",
            "else",
            "printf '%s\\n' 'cmux: SSH foreground authentication token missing, readiness not reported' >&2;",
            requireSuccess ? "exit 255;" : ":;",
            "fi;",
            "unset \(tokenVariable);",
        ]
    }
}
