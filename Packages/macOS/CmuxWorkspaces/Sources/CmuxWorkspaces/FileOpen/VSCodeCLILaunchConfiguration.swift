public import Foundation

/// The resolved executable, fixed argument prefix, and process environment for
/// launching VS Code's `serve-web`/`code-server` backend.
///
/// A pure `Sendable` value produced by ``VSCodeCLILaunchConfigurationResolver``.
public struct VSCodeCLILaunchConfiguration: Sendable {
    /// The executable to run (cached `code-server` or the `code-tunnel` wrapper).
    public let executableURL: URL
    /// Arguments prepended before the cmux-supplied `serve-web` flags
    /// (`["serve-web"]` for the tunnel wrapper, empty for cached `code-server`).
    public let argumentsPrefix: [String]
    /// The sanitized environment to run the process under.
    public let environment: [String: String]

    /// Creates a launch configuration.
    public init(executableURL: URL, argumentsPrefix: [String], environment: [String: String]) {
        self.executableURL = executableURL
        self.argumentsPrefix = argumentsPrefix
        self.environment = environment
    }
}
