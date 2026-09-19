import Foundation

/// Supplies filesystem-backed sidebar names to settings consumers.
public actor CustomSidebarDiscovery {
    private let directory: URL
    private let fileManager: FileManager

    /// Creates discovery for an injectable sidebar directory.
    /// - Parameters:
    ///   - directory: Directory containing custom sidebar files.
    ///   - fileManager: Filesystem used to discover files.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Returns the initial sidebar names and subsequent directory changes.
    /// - Returns: A stream owned by the caller's observation task.
    public func updates() -> AsyncStream<[String]> {
        let names = CustomSidebarValidator(fileManager: fileManager).discover(in: directory)
            .map { $0.deletingPathExtension().lastPathComponent }
        return AsyncStream { continuation in
            continuation.yield(names)
            continuation.finish()
        }
    }
}
