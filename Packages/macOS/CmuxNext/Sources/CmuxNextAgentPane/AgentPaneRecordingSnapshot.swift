import Darwin
import Foundation

/// Pins a file from macOS's floating screenshot or recording preview before the drop returns and
/// the OS may unlink it. Only the descriptor is opened on the main actor. The saved copy is an APFS
/// clone of that descriptor (instant at any size, no bytes read), else a copy a chunk at a time off
/// the main thread: never the whole file in memory, and no size cap (Leo, 2026-10-26: "I ALREADY SAID
/// WE NEED ARBITARRILY LARGE FILES OF ANY TYPE").
nonisolated struct AgentPaneRecordingSnapshot: Sendable {
    private let name: String
    let size: Int
    private let handle: FileHandle

    /// The most one fallback copy step holds in memory.
    static let copyChunkBytes = 4 * 1024 * 1024

    /// Whether this is a file in macOS's temporary floating-preview folder: a recording, or a
    /// screenshot whose original the page uploads after its preview. Ordinary files keep their own
    /// paths. Comparing the two `/var` spellings needs no file-system work at drag time.
    static func needsSnapshot(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
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
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            close(descriptor)
            return nil
        }
        return Self(name: url.lastPathComponent, size: Int(info.st_size), handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    /// Saves the pinned bytes, even after the original path disappeared, as `folder/<name>` (the
    /// folder made owner-only, the file owner-only): its path, or nil. A file that changed size
    /// since the drop, or that could not be read or written, is refused (and nothing is left at the
    /// target) instead of advertising the temporary path. The descriptor closes on every exit.
    @concurrent func save(into folder: URL) async -> URL? {
        defer { try? handle.close() }
        let target = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let source = handle.fileDescriptor
        var info = stat()
        guard fstat(source, &info) == 0, Int(info.st_size) == size else { return nil }
        if fclonefileat(source, AT_FDCWD, target.path, 0) == 0 {
            guard chmod(target.path, 0o600) == 0 else {
                unlink(target.path)
                return nil
            }
            return target
        }
        guard !Task.isCancelled, copy(from: source, to: target) else {
            unlink(target.path)
            return nil
        }
        return target
    }

    /// Copies `size` bytes of `source` to a new owner-only `target` a chunk at a time, and checks
    /// the source did not grow meanwhile.
    private func copy(from source: Int32, to target: URL) -> Bool {
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return false }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: Self.copyChunkBytes)
        var offset = 0
        while offset < size {
            if Task.isCancelled { return false }
            let want = min(Self.copyChunkBytes, size - offset)
            let read = buffer.withUnsafeMutableBytes { pread(source, $0.baseAddress, want, off_t(offset)) }
            guard read > 0 else { return false }
            var written = 0
            while written < read {
                let wrote = buffer.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return -1 }
                    return write(output, base + written, read - written)
                }
                guard wrote > 0 else { return false }
                written += wrote
            }
            offset += read
        }
        var extra: UInt8 = 0
        return pread(source, &extra, 1, off_t(size)) == 0
    }
}
