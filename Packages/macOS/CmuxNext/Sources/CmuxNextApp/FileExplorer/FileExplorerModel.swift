import CmuxNextFiles
import CmuxNextPages
import CmuxNextOnboarding
import Foundation
import Observation
import CmuxNextFilesUI
import CmuxNextHistory

/// The right sidebar's file explorer (classic's Files mode): a folder tree
/// rooted at the focused terminal's folder, folders first, hidden items left
/// out, with one selected row, each row with its git state. Listing runs off
/// the main actor through the injected ``DirectoryListing`` and git through
/// the injected runner, so tests drive it against a temp folder and a fake git.
/// A file-system watch on the root and its repository's `.git` folder
/// (``FileTreeWatching``) lists the tree again after a change made outside cmux.
@MainActor
@Observable
final class FileExplorerModel {
    /// The folder the tree shows; nil before the first ``setRoot(_:)``.
    private(set) var root: URL?
    /// The visible rows, in display order.
    private(set) var rows: [FileExplorerRow] = []
    /// The selected row's item.
    var selection: URL?
    /// The root could not be read (the system's message); nil while it lists.
    private(set) var failure: String?
    /// The root is in a privacy-protected folder the person has not asked to see this session
    /// (LAUNCH-NO-TCC-PROMPTS): nothing is listed or watched there until ``setRoot(_:asked:)``
    /// with `asked`, the section's Show Contents button.
    private(set) var held = false

    @ObservationIgnored private let lister: any DirectoryListing
    @ObservationIgnored private let git: any MarkdownGitRunning
    @ObservationIgnored private var children: [URL: [FileEntry]] = [:]
    /// Git states (``FileGitState`` raw values) by the item's absolute path (symlinks resolved, as git prints them).
    @ObservationIgnored private var gitStates: [String: String] = [:]
    /// Folders (absolute, resolved) with a changed item inside.
    @ObservationIgnored private var changedFolders: Set<String> = []
    /// The root with symlinks resolved, the prefix git's paths share.
    @ObservationIgnored private var resolvedRoot = ""
    @ObservationIgnored private var expanded: Set<URL> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let watcher: any FileTreeWatching
    /// The folders the running watch covers, and its task.
    @ObservationIgnored private var watched: [URL] = []
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// Whether a folder is privacy-protected (``inProtectedFolder(_:)``; a fake in tests).
    @ObservationIgnored private let isProtected: @MainActor (URL) -> Bool
    /// Protected folders the person asked to see: these and the folders inside them list.
    @ObservationIgnored private var asked: Set<URL> = []

    /// - Parameter isProtected: Whether a folder is privacy-protected; by default the one
    ///   protected-folder list, by the folder's spelling.
    init(lister: any DirectoryListing = DirectoryLister(), git: any MarkdownGitRunning = ProcessMarkdownGitRunner(),
         watcher: any FileTreeWatching = FileTreeWatcher(),
         isProtected: @escaping @MainActor (URL) -> Bool = { FileExplorerModel.inProtectedFolder($0) }) {
        self.lister = lister
        self.git = git
        self.watcher = watcher
        self.isProtected = isProtected
    }

    /// Whether `folder` is in a privacy-protected folder (~/Downloads, ~/Desktop, iCloud Drive,
    /// another volume), by its spelling: resolving it would read inside.
    nonisolated static func inProtectedFolder(_ folder: URL) -> Bool {
        PrivacyFolder.containing(folder.standardizedFileURL.path, homePath: NSHomeDirectory()) != nil
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        watching?.cancel()
    }

    /// Watches `folders` (the root, and the repository's `.git` folder): each burst of changes
    /// lists the tree again. The same folders keep the running watch.
    private func watch(_ folders: [URL]) {
        guard folders != watched else { return }
        watched = folders
        watching?.cancel()
        let changes = watcher.changes(under: folders)
        watching = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.reload()
            }
        }
    }

    /// Shows the tree of `folder`; the same folder only re-reads it. A privacy-protected folder
    /// the person has not asked for is held (``held``): it is not read.
    /// - Parameter asked: The person asked to see this folder (Show Contents).
    func setRoot(_ folder: URL, asked: Bool = false) async {
        let folder = folder.standardizedFileURL
        if folder != root {
            root = folder
            children = [:]
            expanded = []
            selection = nil
        }
        if asked { self.asked.insert(folder) }
        guard AppHistoryRules.fileMayRead(protected: isProtected(folder), folder: folder.path, asked: self.asked.map(\.path)) else {
            held = true
            generation += 1
            failure = nil
            children = [:]
            rows = []
            watching?.cancel()
            watching = nil
            watched = []
            return
        }
        held = false
        await reload()
    }

    /// Lists the root and every expanded folder again (the folder may have changed since).
    func reload() async {
        guard let root, !held else { return }
        generation += 1
        let mine = generation
        var listed: [URL: [FileEntry]] = [:]
        do {
            listed[root] = try await lister.list(root)
        } catch {
            guard mine == generation else { return }
            failure = error.localizedDescription
            children = [:]
            rows = []
            return
        }
        for folder in expanded { listed[folder] = (try? await lister.list(folder)) ?? [] }
        let status = await readGit(root)
        guard mine == generation else { return }
        failure = nil
        children = listed
        (resolvedRoot, gitStates, changedFolders) = (status.root, status.states, status.folders)
        rebuild()
        watch([root] + (status.top.map { [URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(".git", isDirectory: true)] } ?? []))
    }

    /// Expands `folder` when it is collapsed (a new item goes inside it).
    func expand(_ folder: URL) async {
        if !expanded.contains(folder) { await toggle(folder) }
    }

    /// `git status` of the repository holding `root` (read-only, no optional locks): nothing outside one.
    private func readGit(_ root: URL) async -> (root: String, states: [String: String], folders: Set<String>, top: String?) {
        let resolved = root.resolvingSymlinksInPath().path
        guard let top = await git.run(["rev-parse", "--show-toplevel"], in: root.path), top.status == 0 else { return (resolved, [:], [], nil) }
        let topPath = URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        guard !topPath.isEmpty, let output = await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: topPath),
              output.status == 0 else { return (resolved, [:], [], nil) }
        let tree = AppHistoryRules.fileGit(top: topPath, entries: FileGitState.parse(output.output).mapValues(\.rawValue))
        return (resolved, tree.states, tree.folders, topPath)
    }

    /// Expands a collapsed folder (listing it) or collapses an expanded one.
    func toggle(_ folder: URL) async {
        if expanded.remove(folder) != nil {
            rebuild()
            return
        }
        let entries = (try? await lister.list(folder)) ?? []
        expanded.insert(folder)
        children[folder] = entries
        rebuild()
    }

    /// The row of `url`, if it shows.
    func row(_ url: URL) -> FileExplorerRow? { rows.first { $0.url == url } }

    /// The selected row, if it still shows.
    var selectedRow: FileExplorerRow? { selection.flatMap(row) }

    /// `url`'s path under the root ("Sources/App.swift"); the full path outside it.
    func relativePath(of url: URL) -> String {
        AppHistoryRules.fileRelative(url.path, root: root?.path)
    }

    private func rebuild() {
        guard let root else { rows = []; return }
        var urls: [String: URL] = [:]
        var listed: [String: [AppHistoryRules.FileEntry]] = [:]
        for (folder, entries) in children {
            listed[folder.path] = Self.sorted(entries).map { entry in
                let url = entry.url.standardizedFileURL
                urls[url.path] = url
                return AppHistoryRules.FileEntry(path: url.path, name: entry.name, isFolder: entry.kind == .folder)
            }
        }
        rows = AppHistoryRules.fileRows(root: root.path, resolvedRoot: resolvedRoot, children: listed, expanded: expanded.map(\.path),
                                        states: gitStates, folders: changedFolders).map { row in
            FileExplorerRow(url: urls[row.path] ?? URL(fileURLWithPath: row.path, isDirectory: row.isFolder), name: row.name,
                            depth: row.depth, isFolder: row.isFolder, isExpanded: row.isExpanded,
                            git: row.git.flatMap(FileGitState.init(rawValue:)))
        }
    }

    /// Folders first, then by name as Finder sorts; hidden items left out.
    private static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter { !$0.isHidden }.sorted { lhs, rhs in
            let lhsFolder = lhs.kind == .folder, rhsFolder = rhs.kind == .folder
            if lhsFolder != rhsFolder { return lhsFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
