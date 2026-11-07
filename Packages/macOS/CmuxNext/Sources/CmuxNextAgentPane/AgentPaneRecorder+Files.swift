import Foundation

/// The recorder's files and sizes, pure or off the main actor: where a movie is, what it is
/// named, its pixel size, which paths Copy and Save take, and the sweep of old movies.
extension AgentPaneRecorder {
    /// The movie's name, as macOS names its own: "Recording 2026-11-07 14.32.05.mp4".
    nonisolated static func name(_ date: Date) -> String { "Recording \(AgentPaneCapture.stamp(date)).mp4" }

    /// The movie's pixel size for `points` at `scale`: the backing size, scaled down to
    /// ``maxSide`` on its longest side, each side even (H.264) and at least 2.
    nonisolated static func size(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        let width = Double(points.width) * scale, height = Double(points.height) * scale
        let fit = min(1, Double(maxSide) / max(width, height, 1))
        func even(_ side: Double) -> Int { max(2, Int((side * fit).rounded(.down)) / 2 * 2) }
        return (even(width), even(height))
    }

    /// Pure: `path` as a file URL when it is absolute, has no empty, `.` or `..` part, lies under
    /// one of `folders` (as spelled, or under `/private` as realpath spells `/var` and `/tmp`) and
    /// is exactly one of `written`.
    nonisolated static func owned(_ path: String, in folders: [URL], written: Set<String>) -> URL? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), written.contains(path) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        let inside = folders.contains { folder in
            let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            return path.hasPrefix(root) || path.hasPrefix("/private" + root)
        }
        return inside ? URL(fileURLWithPath: path) : nil
    }

    /// A movie file's identity, its device and inode: the file the page was given, so a file put
    /// at its path afterwards is never the one Copy or Save takes.
    nonisolated struct FileIdentity: Sendable, Equatable {
        let device: Int64
        let inode: UInt64

        init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    /// Off the main actor: the identity of the regular file at `path` (a link is none).
    nonisolated static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(info)
    }

    /// Off the main actor: moves `movie` (a regular file, `expected` when given) into `upload`, a
    /// fresh folder made here, and removes its own recording folder (the path as made, never
    /// resolved through a link); nil, with `movie` left in place, when it could not. An `upload` that
    /// already exists is someone else's: it is neither used nor removed. Only the folder made
    /// here, still empty, is removed after a failed move.
    nonisolated static func keep(_ movie: URL, in upload: URL, expected: FileIdentity? = nil) -> URL? {
        let kept = upload.appendingPathComponent(movie.lastPathComponent)
        let files = FileManager.checked
        // Only the very file the writer finished (a link or another file in its place stays put).
        guard let found = identity(movie.path), expected.map({ $0 == found }) ?? true else { return nil }
        do {
            try files.createDirectory(at: upload.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createDirectory(at: upload, withIntermediateDirectories: false)
        } catch {
            return nil
        }
        do {
            try files.moveItem(at: movie, to: kept)
        } catch {
            try? files.removeItem(at: upload)
            return nil
        }
        try? files.removeItem(at: movie.deletingLastPathComponent())
        return kept
    }

    /// Off the main actor: removes the folders in `folder` that are not `keeping` (the movies this
    /// process handed out, and the one starting) and are over a day old. A handed-out movie of a
    /// local chat lives in its Chat Uploads folder, not here (``keep(_:in:)``); what stays here is
    /// one nobody was given, or one a chat on another computer had copied. Another cmux on this
    /// Mac writes here too; a day is past any recording it still holds unattached.
    nonisolated static func sweep(_ folder: URL, keeping: Set<String>, now: Date) {
        let files = FileManager.checked
        guard let items = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items where !keeping.contains(item.lastPathComponent) {
            guard let modified = (try? files.attributesOfItem(atPath: item.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
            try? files.removeItem(at: item)
        }
    }
}
