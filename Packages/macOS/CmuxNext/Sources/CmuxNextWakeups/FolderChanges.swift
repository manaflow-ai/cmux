public import Foundation

/// Changes to the contents of some folders as an `AsyncStream`: one element per burst of
/// file-system events, never a poll (plans/cmux-next/idle-wakeups.md). A folder that does not
/// exist yet is watched through its nearest existing parent and is watched itself once made.
///
/// Each element comes after the watch is armed again, so a change between two elements is
/// either seen by the new watch or happened before the element, and the consumer's work for the
/// element (re-reading the folders) covers it.
///
/// ```swift
/// for await _ in FolderChanges(folders: [wallpapers, userImages]).events() { rebuild() }
/// ```
public struct FolderChanges: Sendable {
    /// The folders whose contents matter.
    public let folders: [URL]

    public init(folders: [URL]) {
        self.folders = folders
    }

    /// One element after each burst of changes in any watched folder. Ends when the consumer
    /// stops iterating (the watches are cancelled with it).
    public func events() -> AsyncStream<Void> {
        let folders = folders
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // task-owner: the stream's watch loop; cancelled when the consumer stops iterating
        let loop = Task.detached(priority: .utility) {
            var armed = Self.arm(folders)
            // wakeup-allow: each pass waits for one file-system event in a watched folder, never polls
            while !Task.isCancelled {
                var iterator = armed.events.makeAsyncIterator()
                guard await iterator.next() != nil else { break }
                // Re-arm first (a folder may have appeared), then tell the consumer.
                let next = Self.arm(folders)
                armed.cancel()
                armed = next
                continuation.yield()
            }
            armed.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }

    /// Watches the nearest existing folder of each of `folders`.
    private static func arm(_ folders: [URL]) -> FolderWatch {
        let paths = Set(folders.map { nearestExistingFolder(of: $0.path) })
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
        let sources = paths.compactMap { folder -> (any DispatchSourceFileSystemObject)? in
            let fd = open(folder, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link],
                                                                   queue: .global(qos: .utility))
            source.setEventHandler { continuation.yield() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
        return FolderWatch(events: events, sources: sources, finish: { continuation.finish() })
    }
}

/// The deepest existing folder on `path`, `path` itself included (`/` at worst).
private func nearestExistingFolder(of path: String) -> String {
    var directory = path
    var isFolder: ObjCBool = false
    while !(FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder) && isFolder.boolValue),
          directory != "/", !directory.isEmpty {
        directory = (directory as NSString).deletingLastPathComponent
    }
    return directory.isEmpty ? "/" : directory
}
