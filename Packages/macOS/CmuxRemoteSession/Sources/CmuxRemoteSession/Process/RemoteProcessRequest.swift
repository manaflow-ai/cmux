public import Foundation

/// One subprocess invocation the coordinator hands to its process runner:
/// the executable, argv, optional environment/working directory/stdin, and
/// the timeout after which the process is terminated.
public struct RemoteProcessRequest: Sendable {
    /// Absolute path of the executable to launch.
    public let executable: String
    /// Argument vector (excluding the executable).
    public let arguments: [String]
    /// Process environment, or `nil` to inherit.
    public let environment: [String: String]?
    /// Working directory, or `nil` to inherit.
    public let currentDirectory: URL?
    /// Data written to stdin (the write end is closed afterwards), or `nil`
    /// to attach the null device.
    public let stdin: Data?
    /// Seconds after which a still-running process is terminated and the run
    /// fails with the legacy timeout error.
    public let timeout: TimeInterval

    /// Creates a request; optional fields default to nil/inherit.
    public init(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdin = stdin
        self.timeout = timeout
    }
}
