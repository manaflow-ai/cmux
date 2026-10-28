import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDiff
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
        // A turn belongs to its chat: the empty state offers the default scope for it.
        case .turn: "branch"
        }
    }
}

/// The diff viewer's recent repositories, newest first, at most ``limit``,
/// recorded on every open (empty state, palette, keyboard, CLI) and kept in
/// one small JSON file beside the tag's state (`diff-recents.json`). Reads and
/// writes run on the runner's files lane, writes in order.
final class DiffRecents {
    static let limit = 32
    static let fileName = "diff-recents.json"

    let url: URL
    /// The app's blocking-work lanes: the file reads and writes run there, never on the pool.
    let runner: any MayBlockRunner
    private var items: [DiffRecent]?
    private var loading: Task<[DiffRecent]?, Never>?
    private var saving: Task<Void, Never>?

    init(url: URL, runner: any MayBlockRunner) {
        self.url = url
        self.runner = runner
    }

    /// Beside the build's daemon state, as SidebarSnapshotFile does
    /// (per-build isolation S5): never another build's tag folder.
    static func standardURL(launch: LaunchIdentity) -> URL {
        SidebarSnapshotFile.buildDirectory(launch: launch).appending(path: fileName)
    }

    /// The recents, newest first; none when the read was refused.
    func list() async -> [DiffRecent] {
        await load() ?? []
    }

    /// The recents, read once; nil when the read was refused (the next call reads again).
    private func load() async -> [DiffRecent]? {
        if let items { return items }
        let task = loading ?? Task { [url, runner] in await Self.read(url, on: runner) }
        loading = task
        guard let read = await task.value else {
            loading = nil
            return nil
        }
        if items == nil { items = read }
        return items ?? read
    }

    /// `cmux.diff.recents`: `{home, items}`.
    func page() async -> CmuxNextSettings.JSONValue {
        ["home": .string(NSHomeDirectory()), "items": .array(await list().map(\.json))]
    }

    /// Moves `repository` to the front.
    /// Drops the record when the file could not be read (quit began): writing then would replace the other recents.
    func record(_ repository: DiffRepository, source: DiffOpenSource, at date: Date = Date()) async {
        guard var current = await load() else { return }
        current.removeAll { $0.path == repository.root }
        current.insert(DiffRecent(path: repository.root, name: repository.name, openedAt: (date.timeIntervalSince1970 * 1000).rounded(),
                                  source: DiffRecent.sourceKind(source), branch: repository.branch), at: 0)
        items = Array(current.prefix(Self.limit))
        let snapshot = items ?? [], url = url, runner = runner, previous = saving
        saving = Task {
            await previous?.value
            await Self.write(snapshot, to: url, on: runner)
        }
    }

    /// Waits for the writes started so far (tests).
    func flush() async { await saving?.value }

    /// The file's recents, newest first ([] for a missing or unreadable file); nil when the lane refused the
    /// read (quit began, or the caller was cancelled), which is not an empty file.
    private static func read(_ url: URL, on runner: any MayBlockRunner) async -> [DiffRecent]? {
        try? await runner.runFiles(.userVisible) { () -> [DiffRecent] in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1024 * 1024,
                  let data = try? Data(blockingContentsOf: url),
                  let items = try? JSONDecoder().blockingDecode([DiffRecent].self, from: data) else { return [] }
            return items.sorted { $0.openedAt > $1.openedAt }
        }
    }

    /// One small atomic replace; quit waits for it.
    private static func write(_ items: [DiffRecent], to url: URL, on runner: any MayBlockRunner) async {
        _ = try? await runner.runFiles(.bestEffort, shutdown: .blockShutdown) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(items) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
