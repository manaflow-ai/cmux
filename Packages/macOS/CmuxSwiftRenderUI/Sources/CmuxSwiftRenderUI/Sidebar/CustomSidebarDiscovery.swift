import CmuxFoundation
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
        let watcher = FileWatcher(path: directory.path)
        let (stream, continuation) = AsyncStream<[String]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let initial = names()
        continuation.yield(initial)
        let task = Task {
            var previous = initial
            for await _ in watcher.events {
                guard !Task.isCancelled else { break }
                let current = names()
                if current != previous {
                    continuation.yield(current)
                    previous = current
                }
            }
            await watcher.stop()
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    private func names() -> [String] {
        CustomSidebarValidator(fileManager: fileManager).discover(in: directory)
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}
