import Foundation

/// The final local terminal spawn values authorized by the pre-spawn gate.
public struct SpawnHookGrant: Sendable, Equatable {
    /// The final command, or `nil` for the default shell.
    public let command: String?

    /// The final working directory, if any.
    public let workingDirectory: String?

    /// Environment values to merge last into the spawned terminal environment.
    public let environmentOverrides: [String: String]

    /// Creates a spawn grant.
    /// - Parameters:
    ///   - command: The final command, or `nil` for the default shell.
    ///   - workingDirectory: The final working directory, if any.
    ///   - environmentOverrides: Environment values to merge last.
    public init(command: String?, workingDirectory: String?, environmentOverrides: [String: String]) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
    }
}
