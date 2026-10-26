import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// Where one app's `SidebarSnapshotDocument` lives, and its read and atomic
/// write. The read runs once per launch on the files lane from `main`
/// (``startLaunchRead(in:reader:)``; the file is small and capped), so the
/// sidebar's first frame never waits for the daemon or reads on the main thread.
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
    /// another schema. Blocking (checked): the launch read's body.
    func read(with reader: LaunchFileReader = LaunchFileReader()) -> SidebarSnapshotDocument? {
        guard let data = reader.data(at: url, maximumBytes: Self.maximumBytes),
              let document = try? JSONDecoder().blockingDecode(SidebarSnapshotDocument.self, from: data),
              document.schemaVersion == SidebarSnapshotDocument.schemaVersion else { return nil }
        return document
    }

    /// Reads and decodes the saved document on `work`'s files lane (``read(with:)``); an empty document when
    /// there is none or quit drops the read.
    func startLaunchRead(on work: BackgroundWork, reader: LaunchFileReader = LaunchFileReader()) -> LaunchRead<SidebarSnapshotDocument> {
        LaunchRead(on: work, dropped: SidebarSnapshotDocument()) { read(with: reader) ?? SidebarSnapshotDocument() }
    }

    /// As ``startLaunchRead(on:reader:)``, after every read posted to `sequence` before it: `main` posts it before
    /// the settings read, so the launch window's sidebar has it when the services are made.
    func startLaunchRead(in sequence: WorkSequence, reader: LaunchFileReader = LaunchFileReader()) -> LaunchRead<SidebarSnapshotDocument> {
        LaunchRead(in: sequence, dropped: SidebarSnapshotDocument()) { read(with: reader) ?? SidebarSnapshotDocument() }
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
