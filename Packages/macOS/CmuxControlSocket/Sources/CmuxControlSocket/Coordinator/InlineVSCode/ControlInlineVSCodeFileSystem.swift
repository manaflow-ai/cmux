import Foundation

/// Injectable filesystem access for the inline VS Code worker-lane command.
public struct ControlInlineVSCodeFileSystem: Sendable {
    /// Returns the process working directory used for relative paths.
    public let currentDirectoryPath: @Sendable () -> String

    /// Reports whether a path exists and whether it is a directory.
    public let inspectPath: @Sendable (String) -> (exists: Bool, isDirectory: Bool)

    /// Creates an injectable filesystem seam.
    ///
    /// - Parameters:
    ///   - currentDirectoryPath: Returns the base directory for relative paths.
    ///   - inspectPath: Reports path existence and directory status.
    public init(
        currentDirectoryPath: @escaping @Sendable () -> String,
        inspectPath: @escaping @Sendable (String) -> (exists: Bool, isDirectory: Bool)
    ) {
        self.currentDirectoryPath = currentDirectoryPath
        self.inspectPath = inspectPath
    }

    /// Creates the production filesystem seam.
    public init() {
        currentDirectoryPath = { FileManager().currentDirectoryPath }
        inspectPath = { path in
            let fileManager = FileManager()
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            return (exists, isDirectory.boolValue)
        }
    }
}
