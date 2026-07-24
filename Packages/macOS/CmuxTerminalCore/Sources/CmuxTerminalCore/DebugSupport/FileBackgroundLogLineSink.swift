import Foundation

/// Production ``BackgroundLogLineSink`` that appends each line to a file through a
/// single long-lived `FileHandle` (opened and seeked to end once).
///
/// An `actor` rather than a lock-guarded class: the handle and its open-once flag
/// are actor-isolated, so the type is `Sendable` with compiler-verified isolation
/// and no `@unchecked`. The writer's consumer awaits each `write(_:)`, so appends
/// stay serialized and in order.
actor FileBackgroundLogLineSink: BackgroundLogLineSink {
    private let fileURL: URL
    private var handle: FileHandle?
    private var handleResolved = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8), let handle = resolvedHandle() else { return }
        try? handle.write(contentsOf: data)
    }

    /// Lazily opens (and seeks to end of) the handle on first write, creating the
    /// file if needed. Failures are cached so a bad path is not retried per line.
    private func resolvedHandle() -> FileHandle? {
        if handleResolved {
            return handle
        }
        handleResolved = true
        let path = fileURL.path
        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: fileURL)
        try? opened?.seekToEnd()
        handle = opened
        return opened
    }
}
