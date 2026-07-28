import Foundation

/// Injectable caller-directory access for inline VS Code path resolution.
public struct ControlInlineVSCodeFileSystem: Sendable {
    /// Returns the process working directory used for relative paths.
    public let currentDirectoryPath: @Sendable () -> String

    /// Creates an injectable filesystem seam.
    public init(
        currentDirectoryPath: @escaping @Sendable () -> String
    ) {
        self.currentDirectoryPath = currentDirectoryPath
    }

    /// Creates the production caller-directory seam.
    public init() {
        currentDirectoryPath = { FileManager().currentDirectoryPath }
    }
}
