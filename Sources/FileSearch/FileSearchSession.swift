import CmuxFileSearch
import Foundation

/// Find state for one workspace: its query, options and results. Switching
/// workspaces and back, or switching the sidebar to Files and back, shows
/// the same search again.
@MainActor
final class FileSearchSession {
    let engine: FileSearchEngine
    var query = FileSearchQuery()
    var showsDetails = false
    /// A content revision arrived while searching; search again when done.
    var needsRefreshAfterSearch = false
    /// Replaces the scope's backend. Tests drive searches through it.
    var backendOverride: (any FileSearchBackend)?
    /// The Find panel currently showing this session. Only it receives
    /// engine events, so a hidden panel cannot take them over.
    weak var owner: AnyObject?
    private let root: RootPath

    init(clock: any Clock<Duration> = ContinuousClock()) {
        let root = RootPath()
        self.root = root
        engine = FileSearchEngine(clock: clock) { path in
            FileExplorerTerminalPathInsertion.relativePath(for: path, rootPath: root.value)
        }
    }

    /// Where the results in `engine.tree` came from.
    var rootPath: String { root.value }

    /// Records the root the next results belong to.
    func prepare(rootPath: String) {
        root.value = rootPath
    }

    /// Shared with the tree's path closure without retaining the session.
    private final class RootPath {
        var value = ""
    }
}

/// Recently used workspace sessions, bounded so results for workspaces the
/// user has left do not accumulate.
@MainActor
final class FileSearchSessionCache {
    static let capacity = 8
    private var sessions: [UUID: FileSearchSession] = [:]
    private var order: [UUID] = []

    /// The session for `workspace`, created with `make` on first use.
    func session(for workspace: UUID, make: () -> FileSearchSession) -> FileSearchSession {
        order.removeAll { $0 == workspace }
        order.append(workspace)
        if let existing = sessions[workspace] { return existing }
        let session = make()
        sessions[workspace] = session
        while order.count > Self.capacity {
            let evicted = order.removeFirst()
            sessions.removeValue(forKey: evicted)?.engine.cancel(clearResults: true)
        }
        return session
    }
}

/// Search history shared by every Find panel, persisted in user defaults.
enum FileSearchHistoryDefaults {
    static let key = "fileSearch.queryHistory"

    static func load(defaults: UserDefaults = .standard) -> FileSearchHistory {
        FileSearchHistory(entries: defaults.stringArray(forKey: key) ?? [])
    }

    static func record(_ pattern: String, defaults: UserDefaults = .standard) {
        var history = load(defaults: defaults)
        history.record(pattern)
        defaults.set(history.entries, forKey: key)
    }
}
