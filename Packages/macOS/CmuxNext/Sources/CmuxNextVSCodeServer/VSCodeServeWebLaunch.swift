public import Foundation

/// One `serve-web` process to start: the binary, its arguments and its environment.
public struct VSCodeServeWebLaunch: Sendable, Equatable {
    /// The directly trusted cached `code-server` binary.
    public var executableURL: URL
    /// The full argument list, ending with `--connection-token-file <path>`.
    public var arguments: [String]
    /// The minimal process environment: basic account, locale, path, shell and temporary-directory values.
    public var environment: [String: String]

    /// Creates a launch.
    /// - Parameters:
    ///   - executableURL: The binary to run.
    ///   - arguments: Its arguments.
    ///   - environment: Its environment.
    public init(executableURL: URL, arguments: [String], environment: [String: String]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }

    /// Process basics only. Node injection, credentials, sockets and unrelated app capabilities do not cross this boundary.
    static func minimalEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = Set(["HOME", "LANG", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER", "__CF_USER_TEXT_ENCODING"])
        return source.filter { key, _ in allowed.contains(key) || key.hasPrefix("LC_") }
    }
}
