import CmuxNextCompat
package import CmuxNextWakeups
package import Foundation

/// Writes staged uploads' chunks (``AgentPaneUploadChunk``) on the files lane, never on the main
/// thread: each chunk is decoded there and appended through one handle per staged file, kept open
/// until ``close(_:)``. Before, the main thread decoded each 512 KiB chunk's base64 and opened,
/// sought, wrote and closed the file for it, which grew with the file's size. The caller writes one
/// chunk of a file at a time, and closes a file only once its last write returned.
package nonisolated final class AgentPaneUploadWriter: Sendable {
    private let handles = Mutex<[String: FileHandle]>([:])

    package init() {}

    /// Appends `chunk` to `file` on `work`'s files lane: whether all of it was written.
    package func append(_ chunk: AgentPaneUploadChunk, to file: URL, work: BackgroundWork) async -> Bool {
        (try? await work.run(.userBlocking, mayBlock: .files) { [self] in write(chunk, to: file) }) ?? false
    }

    /// Appends `chunk` to `file` on `work`'s files lane, opening and closing the file for it, with no
    /// handle kept (a stager that keeps no writer): whether all of it was written.
    package static func appendOnce(_ chunk: AgentPaneUploadChunk, to file: URL, work: BackgroundWork) async -> Bool {
        (try? await work.run(.userBlocking, mayBlock: .files) {
            guard let data = chunk.bytes(), let handle = try? FileHandle(forWritingTo: file) else { return false }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.blockingWrite(contentsOf: data)
                return true
            } catch { return false }
        }) ?? false
    }

    /// Closes `file`'s handle, if it has one. Blocking: call it on a files lane.
    package func close(_ file: URL) {
        let handle = handles.withLock { $0.removeValue(forKey: file.path) }
        try? handle?.close()
    }

    /// Closes `file`'s handle on `work`'s files lane.
    package func close(_ file: URL, work: BackgroundWork) async {
        _ = try? await work.run(.userBlocking, mayBlock: .files) { [self] in close(file) }
    }

    private func write(_ chunk: AgentPaneUploadChunk, to file: URL) -> Bool {
        guard let data = chunk.bytes() else { return false }
        let handle: FileHandle
        if let open = handles.withLock({ $0[file.path] }) {
            handle = open
        } else {
            guard let opened = try? FileHandle(forWritingTo: file) else { return false }
            handles.withLock { $0[file.path] = opened }
            handle = opened
        }
        do {
            try handle.seekToEnd()
            try handle.blockingWrite(contentsOf: data)
            return true
        } catch {
            close(file)
            return false
        }
    }
}
