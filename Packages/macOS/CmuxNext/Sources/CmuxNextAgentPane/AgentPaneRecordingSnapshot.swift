import Darwin
import Foundation

/// Pins a recording from macOS's floating preview before the drop returns and the OS may unlink
/// it. Only the descriptor is opened on the main actor; bytes are read off-main, within the
/// existing local-upload limits, then saved by the app's existing Chat Uploads owner.
nonisolated struct AgentPaneRecordingSnapshot: Sendable {
    private let name: String
    let size: Int
    private let handle: FileHandle

    /// Whether this is a movie in macOS's temporary floating-preview folder. Ordinary files keep
    /// their own paths. Comparing the two `/var` spellings needs no file-system work at drag time.
    static func needsSnapshot(_ url: URL) -> Bool {
        guard url.isFileURL, ["mov", "mp4", "m4v", "webm"].contains(url.pathExtension.lowercased()) else { return false }
        func spelling(_ path: String) -> String { path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path }
        let root = spelling(FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryItems", isDirectory: true).path)
        let path = spelling(url.standardizedFileURL.path)
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/")
        return parts.count == 2 && parts[0].hasPrefix("NSIRD_screencaptureui_")
    }

    /// Opens only this user-dropped regular file, without following a leaf symlink or blocking on
    /// a FIFO. Keeping the descriptor keeps the bytes readable if macOS deletes the preview URL.
    static func pin(_ url: URL) -> Self? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= AgentPaneUpload.maximumFileBytes else {
            close(descriptor)
            return nil
        }
        return Self(name: url.lastPathComponent, size: Int(info.st_size), handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    /// The pinned bytes, even after the original path disappeared. A changing or unreadable file
    /// is refused instead of advertising the temporary path. The descriptor closes on every exit.
    @concurrent func upload() async -> AgentPaneUpload? {
        defer { try? handle.close() }
        var bytes = Data()
        do {
            while bytes.count < size {
                guard !Task.isCancelled,
                      let chunk = try handle.read(upToCount: min(size - bytes.count, 1 << 20)), !chunk.isEmpty else { return nil }
                bytes.append(chunk)
            }
            guard try handle.read(upToCount: 1)?.isEmpty != false else { return nil }
        } catch {
            return nil
        }
        return AgentPaneUpload(name: name, data: bytes)
    }
}
