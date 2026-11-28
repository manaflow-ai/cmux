import AppKit
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// One repository the diff viewer opened (diff-host.md "Empty state",
/// `cmux.diff.recents`): its top level, when, with which source kind, on
/// which branch.
nonisolated struct DiffRecent: Codable, Sendable, Equatable {
    var path: String
    var name: String?
    /// Milliseconds since the epoch.
    var openedAt: Double
    /// `branch`, `uncommitted` (a branch session against HEAD), `staged` or `unstaged`.
    var source: String?
    var branch: String?

    var json: CmuxNextSettings.JSONValue {
        var object: [String: CmuxNextSettings.JSONValue] = ["path": .string(path), "openedAt": .number(openedAt)]
        if let name { object["name"] = .string(name) }
        if let source { object["source"] = .string(source) }
        if let branch { object["branch"] = .string(branch) }
        return .object(object)
    }

    static func sourceKind(_ source: DiffOpenSource) -> String {
        switch source {
        case .branch(let base): base == "HEAD" ? "uncommitted" : "branch"
        case .staged: "staged"
        case .unstaged: "unstaged"
        }
    }
}

/// The diff viewer's recent repositories, newest first, at most ``limit``,
/// recorded on every open (empty state, palette, keyboard, CLI) and kept in
/// one small JSON file beside the tag's state (`diff-recents.json`). Reads and
/// writes run off the main actor, writes in order.
final class DiffRecents {
    static let limit = 32
    static let fileName = "diff-recents.json"

    let url: URL
    private var items: [DiffRecent]?
    private var loading: Task<[DiffRecent], Never>?
    private var saving: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    /// A tagged build keeps it next to the tag's daemon state, an untagged one
    /// in its bundle's support directory (as SidebarSnapshotFile does).
    static func standardURL(launch: LaunchIdentity) -> URL {
        let directory: URL
        if let tag = launch.tag, !tag.isEmpty {
            directory = DaemonLauncher.tagStateDirectory(tag: tag).deletingLastPathComponent()
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: launch.bundleID ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
        }
        return directory.appending(path: fileName)
    }

    /// The recents, newest first.
    func list() async -> [DiffRecent] {
        if let items { return items }
        let task = loading ?? Task { [url] in await Self.read(url) }
        loading = task
        let read = await task.value
        if items == nil { items = read }
        return items ?? read
    }

    /// `cmux.diff.recents`: `{home, items}`.
    func page() async -> CmuxNextSettings.JSONValue {
        ["home": .string(NSHomeDirectory()), "items": .array(await list().map(\.json))]
    }

    /// Moves `repository` to the front.
    func record(_ repository: DiffRepository, source: DiffOpenSource, at date: Date = Date()) async {
        var current = await list()
        current.removeAll { $0.path == repository.root }
        current.insert(DiffRecent(path: repository.root, name: repository.name, openedAt: (date.timeIntervalSince1970 * 1000).rounded(),
                                  source: DiffRecent.sourceKind(source), branch: repository.branch), at: 0)
        items = Array(current.prefix(Self.limit))
        let snapshot = items ?? [], url = url, previous = saving
        saving = Task {
            await previous?.value
            await Self.write(snapshot, to: url)
        }
    }

    /// Waits for the writes started so far (tests).
    func flush() async { await saving?.value }

    @concurrent private static func read(_ url: URL) async -> [DiffRecent] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1024 * 1024,
              // concurrency-allow: @concurrent, one capped read of a small local file
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([DiffRecent].self, from: data) else { return [] }
        return items.sorted { $0.openedAt > $1.openedAt }
    }

    @concurrent private static func write(_ items: [DiffRecent], to url: URL) async {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
