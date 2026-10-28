import CmuxNextCompat
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

    /// In the build's own folder (``buildDirectory(launch:)``), never in
    /// another build's tag folder (per-build isolation S5, cx-is1kf.6).
    static func standard(launch: LaunchIdentity) -> SidebarSnapshotFile {
        SidebarSnapshotFile(url: buildDirectory(launch: launch).appending(path: fileName))
    }

    static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "cmux", directoryHint: .isDirectory)
    }

    /// The stable app-owned root for composer and relaunch drafts.
    static func draftDirectory(launch: LaunchIdentity) -> URL {
        launch.build.draftDirectory(appSupport: applicationSupportDirectory())
    }

    /// Prior per-build roots for this logical app. They are read-only migration sources.
    static func legacyDraftDirectories(launch: LaunchIdentity, appSupport: URL? = nil) -> [URL] {
        let cmux = appSupport ?? applicationSupportDirectory()
        var roots: [URL] = [buildDirectory(launch: launch)]
        if let state = launch.build.daemonStateDirectory(appSupport: cmux) {
            roots.append(state.deletingLastPathComponent())
        }
        // No prefix scan: another channel or shipped tag can begin with this key.
        roots.append(cmux.appending(path: "builds/\(launch.build.key)", directoryHint: .isDirectory))
        if launch.build.keepsAppNames, let tag = launch.tag, !tag.isEmpty {
            roots.append(cmux.appending(path: "tags/\(tag)", directoryHint: .isDirectory))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The folder of this build's small per-build files (sidebar snapshot,
    /// agent drafts and launch images, diff recents and viewed files). A
    /// build that keeps its app names (``BuildIdentity/keepsAppNames``: the
    /// shipped channels, cmux NEXT, a `reload.sh` DEV tag) keeps the folder it
    /// had, so no file moves: `cmux/tags/<tag>/` for a tagged build, its
    /// bundle's support folder for an untagged one. Every other build (its
    /// bundle id names a tag that is not its own, an owned tag, the untagged
    /// DEV build) uses the parent of its key's daemon state,
    /// `cmux/builds/<key>/`.
    static func buildDirectory(launch: LaunchIdentity) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cmux = support.appending(path: "cmux", directoryHint: .isDirectory)
        if !launch.build.keepsAppNames, let state = launch.build.daemonStateDirectory(appSupport: cmux) {
            return state.deletingLastPathComponent()
        }
        if let tag = launch.tag, !tag.isEmpty {
            return DaemonLauncher.tagStateDirectory(tag: tag).deletingLastPathComponent()
        }
        return support.appending(path: launch.bundleID ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
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
