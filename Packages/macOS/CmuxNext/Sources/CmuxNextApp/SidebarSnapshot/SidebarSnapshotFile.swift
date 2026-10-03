import CmuxNextControl
import CmuxNextDaemon
import Foundation

/// Where one app's `SidebarSnapshotDocument` lives, and its synchronous
/// read and atomic write. The read runs once per launch before the first
/// window (the file is small and capped), so the sidebar's first frame
/// never waits for the daemon.
nonisolated struct SidebarSnapshotFile: Sendable {
    static let fileName = "sidebar-snapshot-v1.json"
    /// A larger file is not read (a sidebar of a few hundred rows is ~100 KB).
    static let maximumBytes = 2 * 1024 * 1024

    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// A tagged build keeps it next to the tag's daemon state
    /// (`~/Library/Application Support/cmux/tags/<tag>/`), an untagged one
    /// in its bundle's support directory.
    static func standard(launch: LaunchIdentity) -> SidebarSnapshotFile {
        let directory: URL
        if let tag = launch.tag, !tag.isEmpty {
            directory = DaemonLauncher.tagStateDirectory(tag: tag).deletingLastPathComponent()
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: launch.bundleID ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
        }
        return SidebarSnapshotFile(url: directory.appending(path: fileName))
    }

    /// The saved document; nil when missing, too large, unreadable or of
    /// another schema.
    func read() -> SidebarSnapshotDocument? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
              // concurrency-allow: one capped read of a small local file before the first window, replacing a wait for the daemon
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(SidebarSnapshotDocument.self, from: data),
              document.schemaVersion == SidebarSnapshotDocument.schemaVersion else { return nil }
        return document
    }

    /// Writes `document` atomically, owner-only.
    func write(_ document: SidebarSnapshotDocument) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
