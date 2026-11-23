import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import os

/// Where one app's `SidebarSnapshotDocument` lives, and its synchronous
/// read and atomic write. The read runs once per launch before the first
/// window (the file is small and capped), so the sidebar's first frame
/// never waits for the daemon.
nonisolated struct SidebarSnapshotFile: Sendable {
    static let fileName = "sidebar-snapshot-v1.json"
    /// The file's one size limit: the writer compacts a document to fit under it
    /// (`SidebarSnapshotDocument.fitted`) and the reader refuses a larger file. Leo's
    /// NIGHTLY on 2026-11-18: 4 windows, 178 rows, 53 KB, about 270 bytes a row.
    static let maximumBytes = 2 * 1024 * 1024

    /// What the file reports: a write it had to compact, or a present file it did not read and why.
    enum Event: Equatable, Sendable {
        case compacted(SidebarSnapshotDocument.Compaction)
        case skipped(SkipReason)
    }

    /// Why a present file was not read (a missing one is a first launch, not reported).
    enum SkipReason: Equatable, Sendable {
        case tooLarge(bytes: Int, limit: Int)
        case unreadable(String)
        case undecodable(String)
        case otherSchema(Int)
    }

    let url: URL
    /// Receives every `Event`; the default logs it (category `sidebar-snapshot`).
    let report: @Sendable (Event) -> Void

    init(url: URL, report: @escaping @Sendable (Event) -> Void = { SidebarSnapshotFile.log($0) }) {
        self.url = url
        self.report = report
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar-snapshot")

    static func log(_ event: Event) {
        switch event {
        case let .compacted(c):
            logger.notice("""
            sidebar snapshot compacted to fit: \(c.bytesBefore, privacy: .public) -> \(c.bytesAfter, privacy: .public) bytes, \
            limit \(c.limit, privacy: .public); row detail dropped \(c.droppedRowDetail, privacy: .public), \
            windows dropped \(c.droppedWindows, privacy: .public), rows dropped \(c.droppedRows, privacy: .public)
            """)
        case let .skipped(.tooLarge(bytes, limit)):
            logger.error("sidebar snapshot not read: \(bytes, privacy: .public) bytes is over the limit of \(limit, privacy: .public)")
        case let .skipped(.unreadable(reason)):
            logger.error("sidebar snapshot not read: unreadable: \(reason, privacy: .public)")
        case let .skipped(.undecodable(reason)):
            logger.error("sidebar snapshot not read: undecodable: \(reason, privacy: .public)")
        case let .skipped(.otherSchema(version)):
            logger.error("""
            sidebar snapshot not read: schema \(version, privacy: .public), \
            this build reads \(SidebarSnapshotDocument.schemaVersion, privacy: .public)
            """)
        }
    }

    /// In the build's own folder (``buildDirectory(launch:)``), never in
    /// another build's tag folder (per-build isolation S5, cx-is1kf.6).
    static func standard(launch: LaunchIdentity) -> SidebarSnapshotFile {
        SidebarSnapshotFile(url: buildDirectory(launch: launch).appending(path: fileName))
    }

    /// The folder of this build's small per-build files (sidebar snapshot,
    /// agent drafts and launch images, diff recents and viewed files). A
    /// build that keeps its app names (``BuildIdentity/keepsAppNames``) uses
    /// `cmux-next/tags/<tag>/`, or its bundle's support folder untagged; every
    /// other build `cmux-next/builds/<key>/` (``StateFolderMove`` moved both
    /// out of classic's `cmux`).
    static func buildDirectory(launch: LaunchIdentity) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !launch.build.keepsAppNames, let state = launch.build.daemonStateDirectory(appSupport: DaemonLauncher.nextSupport(support)) {
            return state.deletingLastPathComponent()
        }
        if let tag = launch.tag, !tag.isEmpty {
            return DaemonLauncher.tagStateDirectory(tag: tag).deletingLastPathComponent()
        }
        return support.appending(path: launch.bundleID ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
    }

    /// The saved document; nil when missing, too large, unreadable or of
    /// another schema. Every case but missing is reported with its reason.
    func read() -> SidebarSnapshotDocument? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        guard size <= Self.maximumBytes else {
            report(.skipped(.tooLarge(bytes: size, limit: Self.maximumBytes)))
            return nil
        }
        let data: Data
        do {
            // concurrency-allow: one capped read of a small local file before the first window, replacing a wait for the daemon
            data = try Data(contentsOf: url)
        } catch {
            report(.skipped(.unreadable(String(describing: error))))
            return nil
        }
        let document: SidebarSnapshotDocument
        do {
            document = try JSONDecoder().decode(SidebarSnapshotDocument.self, from: data)
        } catch {
            report(.skipped(.undecodable(String(describing: error))))
            return nil
        }
        guard document.schemaVersion == SidebarSnapshotDocument.schemaVersion else {
            report(.skipped(.otherSchema(document.schemaVersion)))
            return nil
        }
        return document
    }

    /// Writes `document` atomically, owner-only, compacted to fit under
    /// ``maximumBytes`` when it does not (reported).
    func write(_ document: SidebarSnapshotDocument) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let (data, compaction) = try document.fitted(limit: Self.maximumBytes)
        if let compaction { report(.compacted(compaction)) }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
