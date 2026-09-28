internal import Foundation

/// Hands a workspace's SSH foreground-authentication token to the local launch
/// scripts that report `workspace.remote.foreground_auth_ready`.
///
/// The token authorizes a local socket call only. It is never sent to the
/// remote host.
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
        [:]
    }

    /// Shell lines that load the token into a shell variable.
    ///
    /// - Parameter variable: Shell variable that receives the token.
    public func tokenLoadShellLines(into variable: String) -> [String] {
        ["\(variable)=\(Self.shellQuote(token));"]
    }

    /// Shell lines that report foreground-authentication readiness to the
    /// local cmux socket and then clear the token variable.
    ///
    /// Each line ends with `;` or a shell keyword, so callers may join the
    /// lines with newlines or spaces.
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
            "\(payloadVariable)=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\"," +
                "\\\"foreground_auth_token\\\":\\\"$\(tokenVariable)\\\"\(controlPathField)}\";",
            "\"$\(cliVariable)\" --socket \"$\(socketVariable)\" rpc " +
                "workspace.remote.foreground_auth_ready " +
                "\"$\(payloadVariable)\" >/dev/null 2>&1" + failureHandling,
            "unset \(payloadVariable) \(tokenVariable);",
        ]
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
