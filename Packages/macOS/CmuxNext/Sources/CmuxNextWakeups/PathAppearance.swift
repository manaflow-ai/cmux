public import Foundation

/// Waits for a path (a daemon's Unix socket) to exist: an event from the file system, never a poll
/// (plans/cmux-next/idle-wakeups.md: a retry first waits for the event that can make it succeed).
///
/// The wait watches the nearest directory on the path that exists (the daemon's home, else the
/// folder it will be made in) and checks again on each change there, so a client whose daemon is
/// not running yet costs no wakeup until something changes in that folder.
///
/// ```swift
/// if !FileManager.default.fileExists(atPath: socket) { await PathAppearance().wait(for: socket) }
/// ```
public struct PathAppearance: Sendable {
    public init() {}

    /// Returns once `path` exists, or as soon as the calling task is cancelled.
    public func wait(for path: String) async {
        // wakeup-allow: each pass waits for one file-system event in the watched folder, never polls
        while !Task.isCancelled, !FileManager.default.fileExists(atPath: path) {
            await nextChange(near: path)
        }
    }

    /// One change in the nearest existing folder on `path` (or at once when `path` exists by the time
    /// the watch is armed, or the task is cancelled: the stream's iterator ends on cancellation).
    private func nextChange(near path: String) async {
        var directory = (path as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: directory), directory != "/", !directory.isEmpty {
            directory = (directory as NSString).deletingLastPathComponent
        }
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link],
                                                               queue: .global(qos: .utility))
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler { close(fd) }
        source.resume()
        defer {
            source.cancel()
            continuation.finish()
        }
        // Made between the caller's check and the armed watch: no event would come for it.
        if FileManager.default.fileExists(atPath: path) { return }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
    }
}
