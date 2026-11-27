public import Foundation

/// One `serve-web` process to start: the binary, its arguments and its environment.
public struct VSCodeServeWebLaunch: Sendable, Equatable {
    /// The binary: a cached `code-server` or the app's bundled `code-tunnel` CLI.
    public var executableURL: URL
    /// The full argument list, ending with `--connection-token-file <path>`.
    public var arguments: [String]
    /// The process environment (the app's, with VS Code's Node options moved aside).
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
}
