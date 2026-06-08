import CmuxFileWatch
import Foundation
import SwiftUI

/// Backing store for the Notes sidebar tab.
///
/// Owns the per-workspace notes tree as an eagerly-materialized hierarchy of
/// ``NotesTreeNode`` values (notes trees are small, so there is no lazy paging).
/// The filesystem is the source of truth; this store reflects it, watches it for
/// external changes (e.g. the `cmux-notes` skill writing files), and offers the
/// mutations the sidebar performs (new note/folder, move, session-folder sync).
///
/// All access happens on the main thread. Properties are not marked `@MainActor`
/// because `NSOutlineView` data-source/delegate methods call into the store on
/// the main thread without that annotation, matching ``FileExplorerStore``.
final class NotesTreeStore: ObservableObject {
    /// Top-level nodes (children of the workspace notes root).
    @Published private(set) var rootNodes: [NotesTreeNode] = []
    /// Bumped on every structural reload so the outline view reloads its data.
    @Published private(set) var contentRevision = 0
    /// Whether a local workspace is currently bound (false ⇒ empty/disabled tree).
    @Published private(set) var hasWorkspace = false

    /// Loads the sessions (any agent) for a cwd. Injected by the composition root
    /// so the store stays decoupled from `SessionIndexStore` and testable.
    var loadSessions: (@MainActor (String) async -> [NotesSessionDescriptor])?

    private var projectRoot: String?
    private var workspaceTitle: String = ""
    private var cwd: String?
    /// Absolute path to `<projectRoot>/.cmux/notes/<workspace-folder>` (resolved,
    /// not necessarily created yet — materialized on first mutation/sync).
    private(set) var resolvedRootPath: String?

    /// Paths the user has explicitly collapsed. Everything is expanded by
    /// default; only entries listed here stay collapsed across reloads.
    private var collapsedPaths: Set<String> = []

    private var watchers: [FileWatcher] = []
    private var watcherTasks: [Task<Void, Never>] = []
    private var watchedDirs: Set<String> = []
    private var reloadCoalesceTask: Task<Void, Never>?

    private let maxDepth = 12
    private let nodeBudget = 5000
    private let maxWatchers = 256

    // MARK: - Workspace binding

    /// Bind the tree to a workspace, keyed by its `currentDirectory`. Passing a
    /// nil projectRoot/cwd (e.g. a remote workspace or no selection) clears the
    /// tree. Re-binding to the same workspace is a no-op.
    func setWorkspace(title: String, projectRoot: String?, currentDirectory: String?) {
        let cwd = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let projectRoot, let cwd, !cwd.isEmpty else {
            clear()
            return
        }
        let newRoot = NotesTreeStorage.resolveWorkspaceRoot(projectRoot: projectRoot, cwd: cwd)
        let unchanged = hasWorkspace
            && self.projectRoot == projectRoot
            && self.cwd == cwd
            && resolvedRootPath == newRoot
        self.projectRoot = projectRoot
        self.workspaceTitle = title
        self.cwd = cwd
        self.resolvedRootPath = newRoot
        self.hasWorkspace = true
        guard !unchanged else { return }
        reload()
        syncSessionFolders()
    }

    /// Detach from any workspace and empty the tree (remote/no-selection state).
    func clear() {
        guard hasWorkspace || !rootNodes.isEmpty else { return }
        stopWatchers()
        reloadCoalesceTask?.cancel()
        reloadCoalesceTask = nil
        hasWorkspace = false
        projectRoot = nil
        cwd = nil
        resolvedRootPath = nil
        rootNodes = []
        contentRevision &+= 1
    }

    /// Reload from disk + refresh session folders. Call on Notes-tab appear.
    func reloadIfNeeded() {
        guard hasWorkspace else { return }
        reload()
        syncSessionFolders()
    }

    // MARK: - Loading

    /// Rebuild the full node tree from disk and refresh file watchers.
    func reload() {
        guard let root = resolvedRootPath else {
            rootNodes = []
            contentRevision &+= 1
            return
        }
        var budget = nodeBudget
        rootNodes = buildChildren(ofDirectory: root, depth: 0, budget: &budget)
        contentRevision &+= 1
        refreshWatchers(forRoot: root)
    }

    /// Coalesce a burst of file-watch events into a single reload, so many
    /// watchers firing at once don't each trigger a full main-thread rebuild
    /// (the Notes-tab lag). Bounded, cancellable delay (intended coalescing
    /// window), cancelled on teardown.
    func scheduleReload() {
        guard reloadCoalesceTask == nil else { return }
        reloadCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.reloadCoalesceTask = nil
            self.reload()
        }
    }

    private func buildChildren(ofDirectory directory: String, depth: Int, budget: inout Int) -> [NotesTreeNode] {
        guard depth < maxDepth, budget > 0 else { return [] }
        let entries = NotesTreeStorage.listEntries(inDirectory: directory)
        var nodes: [NotesTreeNode] = []
        for entry in entries {
            guard budget > 0 else { break }
            budget -= 1
            let children = entry.kind.isDirectory
                ? buildChildren(ofDirectory: entry.path, depth: depth + 1, budget: &budget)
                : nil
            nodes.append(NotesTreeNode(name: entry.name, path: entry.path, kind: entry.kind, children: children))
        }
        return nodes
    }

    // MARK: - Session folders

    /// Materialize/refresh a session folder for every session (any agent) in
    /// the workspace cwd. No-op when no session loader is wired or no workspace bound.
    func syncSessionFolders() {
        guard let root = resolvedRootPath,
              let cwd,
              let loadSessions,
              let projectRoot
        else { return }
        let title = workspaceTitle
        Task { @MainActor [weak self] in
            let descriptors = await loadSessions(cwd)
            guard let self, self.resolvedRootPath == root else { return }
            guard !descriptors.isEmpty else { return }
            // Materialize the workspace root (+ _workspace.json) lazily, only once
            // there is something to put in it.
            let ensured = (try? NotesTreeStorage.ensureWorkspaceRoot(
                projectRoot: projectRoot, cwd: cwd, title: title
            )) ?? root
            NotesTreeStorage.syncSessionFolders(inRoot: ensured, descriptors: descriptors)
            self.resolvedRootPath = ensured
            self.reload()
        }
    }

    // MARK: - Mutations

    /// Create a new empty note in `folder` (or the workspace root if nil).
    @discardableResult
    func newNote(inFolder folder: String? = nil) -> String? {
        guard let target = try? ensureRoot(folder: folder) else { return nil }
        let path = try? NotesTreeStorage.newNote(inFolder: target)
        reload()
        return path
    }

    /// Create a new subfolder in `folder` (or the workspace root if nil).
    @discardableResult
    func newFolder(inFolder folder: String? = nil) -> String? {
        guard let target = try? ensureRoot(folder: folder) else { return nil }
        let path = try? NotesTreeStorage.newFolder(inFolder: target)
        reload()
        return path
    }

    /// Move a note/folder into `destinationFolder`. Returns the new path, or nil
    /// on failure (e.g. invalid move).
    @discardableResult
    func move(sourcePath: String, intoFolder destinationFolder: String) -> String? {
        let moved = try? NotesTreeStorage.move(sourcePath: sourcePath, intoFolder: destinationFolder)
        reload()
        return moved
    }

    /// Move a note/folder to the system trash. Confined to within the workspace
    /// root so the tree can never delete outside its own subtree.
    func delete(path: String) {
        guard let root = resolvedRootPath,
              NotesTreeStorage.isWithin(child: path, orEqualTo: root),
              (path as NSString).standardizingPath != (root as NSString).standardizingPath
        else { return }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        reload()
    }

    /// Ensure the workspace root exists and return the mutation target directory.
    /// `folder` (when given) must lie within the workspace root.
    private func ensureRoot(folder: String?) throws -> String {
        guard let projectRoot, let cwd else {
            throw NotesTreeStorageError.invalidMove
        }
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: cwd, title: workspaceTitle
        )
        resolvedRootPath = root
        guard let folder, NotesTreeStorage.isWithin(child: folder, orEqualTo: root) else { return root }
        return folder
    }

    // MARK: - Expansion

    /// Expanded by default; collapsed only if the user collapsed this path.
    func isExpanded(_ node: NotesTreeNode) -> Bool { !collapsedPaths.contains(node.path) }

    func setExpanded(_ node: NotesTreeNode, expanded: Bool) {
        if expanded { collapsedPaths.remove(node.path) } else { collapsedPaths.insert(node.path) }
    }

    // MARK: - File watching

    /// Watch the workspace root, its nearest existing ancestor (so the root being
    /// created is observed), and every directory in the tree, so external writes
    /// refresh the sidebar. Only rebuilds when the watched-directory set changes.
    private func refreshWatchers(forRoot root: String) {
        var dirs = Set<String>()
        dirs.insert(nearestExistingDirectory(of: root))
        collectDirectories(rootNodes, into: &dirs)
        if dirs.count > maxWatchers {
            // Defensive cap: prefer the shallowest paths.
            dirs = Set(dirs.sorted { $0.count < $1.count }.prefix(maxWatchers))
        }
        guard dirs != watchedDirs else { return }
        stopWatchers()
        watchedDirs = dirs
        for dir in dirs {
            let watcher = FileWatcher(path: dir, throttle: .milliseconds(300))
            let events = watcher.events
            watchers.append(watcher)
            watcherTasks.append(Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.scheduleReload()
                }
            })
        }
    }

    private func collectDirectories(_ nodes: [NotesTreeNode], into set: inout Set<String>) {
        for node in nodes where node.kind.isDirectory {
            set.insert(node.path)
            if let children = node.children { collectDirectories(children, into: &set) }
        }
    }

    private func nearestExistingDirectory(of path: String) -> String {
        let fm = FileManager.default
        var current = (path as NSString).standardizingPath
        while !current.isEmpty, current != "/" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: current, isDirectory: &isDir), isDir.boolValue {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return current.isEmpty ? "/" : current
    }

    private func stopWatchers() {
        for task in watcherTasks { task.cancel() }
        watcherTasks = []
        watchers = []
        watchedDirs = []
    }

    deinit {
        for task in watcherTasks { task.cancel() }
        reloadCoalesceTask?.cancel()
    }
}
