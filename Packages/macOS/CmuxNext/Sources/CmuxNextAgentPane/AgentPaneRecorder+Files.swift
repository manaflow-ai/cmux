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
    /// `folder` (as spelled, or under `/private` as realpath spells `/var` and `/tmp`) and is
    /// exactly one of `written`.
    nonisolated static func owned(_ path: String, in folder: URL, written: Set<String>) -> URL? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), written.contains(path) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard path.hasPrefix(root) || path.hasPrefix("/private" + root) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Off the main actor: removes the folders in `folder` that are not `keeping` (the movies this
    /// process handed out, and the one starting) and are over a day old. Another cmux on this Mac
    /// writes here too; a day is past any recording it still holds unattached.
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
