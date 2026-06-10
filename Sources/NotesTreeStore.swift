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
    /// Abbreviated workspace path shown in the header bar — the same treatment
    /// as the Files tab's header (cwd with the home directory as `~`). Changes
    /// only when the bound cwd changes, which always reloads the tree.
    private(set) var headerDisplayPath = ""

    private var projectRoot: String?
    private var workspaceTitle: String = ""
    private var cwd: String?
    /// Absolute path to `<projectRoot>/.cmux/notes/<workspace-folder>` (resolved,
    /// not necessarily created yet — materialized on first mutation/sync).
    private(set) var resolvedRootPath: String?
    /// Absolute path to `<projectRoot>/.cmux/notes` — the flat-note directory
    /// shared by the project, and the confinement boundary for tree mutations.
    private(set) var notesDirPath: String?
    /// The workspace cwd's most recent sessions, live from the agents' session
    /// stores (the Vault's scanners). Rendered as virtual rows; sessions that
    /// already have a materialized folder anywhere in the tree are skipped at
    /// merge time.
    private var liveSessions: [NotesSessionDescriptor] = []
    /// Cap on virtual session rows so a busy cwd doesn't flood the sidebar
    /// (the disk-materializing predecessor of this feature was removed for
    /// exactly that flood).
    private let liveSessionLimit = 20

    /// Paths the user has explicitly collapsed. Everything is expanded by
    /// default; only entries listed here stay collapsed across reloads.
    private var collapsedPaths: Set<String> = []

    private var watchers: [FileWatcher] = []
    private var watcherTasks: [Task<Void, Never>] = []
    private var watchedDirs: Set<String> = []
    private var reloadCoalesceTask: Task<Void, Never>?
    private var markerRefreshTask: Task<Void, Never>?
    private var lastMarkerRefresh: Date?
    /// Floor between appear-triggered marker refreshes; Refresh bypasses it.
    private let markerRefreshMinInterval: TimeInterval = 30

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
        self.notesDirPath = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        self.hasWorkspace = true
        self.headerDisplayPath = (cwd as NSString).abbreviatingWithTildeInPath
        guard !unchanged else { return }
        // A different workspace means the previous scan (if any) is stale:
        // cancel it and lift the throttle so the new cwd scans immediately.
        markerRefreshTask?.cancel()
        markerRefreshTask = nil
        lastMarkerRefresh = nil
        liveSessions = []
        reload()
        refreshSessions()
    }

    /// Detach from any workspace and empty the tree (remote/no-selection state).
    func clear() {
        guard hasWorkspace || !rootNodes.isEmpty else { return }
        stopWatchers()
        reloadCoalesceTask?.cancel()
        reloadCoalesceTask = nil
        markerRefreshTask?.cancel()
        markerRefreshTask = nil
        lastMarkerRefresh = nil
        hasWorkspace = false
        projectRoot = nil
        cwd = nil
        resolvedRootPath = nil
        notesDirPath = nil
        rootNodes = []
        liveSessions = []
        headerDisplayPath = ""
        contentRevision &+= 1
    }

    /// Reload from disk (Notes-tab appear). Also kicks the throttled session
    /// refresh so the live Claude/Codex/… rows and dragged-in markers track
    /// the real session stores. No-op without a workspace.
    func reloadIfNeeded() {
        guard hasWorkspace else { return }
        reload()
        refreshSessions()
    }

    /// The Refresh button: reload from disk and force a session refresh
    /// (bypassing the throttle) so an explicit refresh always re-reads live
    /// session data.
    func refreshFromUser() {
        guard hasWorkspace else { return }
        reload()
        refreshSessions(force: true)
    }

    // MARK: - Loading

    /// Rebuild the full node tree and refresh file watchers. The top level is
    /// the union the Notes tab presents: the workspace folder's own contents,
    /// the project's flat notes (`.cmux/notes/*.md`, written by `cmux note`
    /// and the note surface), and the cwd's recent sessions as virtual rows —
    /// skipping sessions that already have a materialized folder somewhere in
    /// the tree.
    func reload() {
        guard let root = resolvedRootPath else {
            rootNodes = []
            contentRevision &+= 1
            return
        }
        var budget = nodeBudget
        var nodes = buildChildren(ofDirectory: root, depth: 0, budget: &budget)
        if let notesDir = notesDirPath {
            nodes.append(contentsOf: NotesTreeStorage.listFlatNotes(inNotesDir: notesDir).map {
                NotesTreeNode(name: $0.name, path: $0.path, kind: $0.kind)
            })
        }
        nodes.append(contentsOf: virtualSessionNodes(materializedInto: nodes))
        nodes.sort {
            NotesTreeStorage.displayOrder(
                NotesTreeEntry(name: $0.name, path: $0.path, kind: $0.kind),
                NotesTreeEntry(name: $1.name, path: $1.path, kind: $1.kind)
            )
        }
        rootNodes = nodes
        contentRevision &+= 1
        refreshWatchers(forRoot: root)
    }

    /// Virtual rows for live sessions that have no materialized folder yet.
    private func virtualSessionNodes(materializedInto nodes: [NotesTreeNode]) -> [NotesTreeNode] {
        guard !liveSessions.isEmpty else { return [] }
        var materializedIds = Set<String>()
        func collect(_ nodes: [NotesTreeNode]) {
            for node in nodes {
                if let marker = node.kind.sessionMarker { materializedIds.insert(marker.sessionId) }
                if let children = node.children { collect(children) }
            }
        }
        collect(nodes)
        return liveSessions.compactMap { descriptor in
            guard !materializedIds.contains(descriptor.sessionId) else { return nil }
            let marker = NotesSessionMarker(
                agent: descriptor.agent,
                sessionId: descriptor.sessionId,
                cwd: descriptor.cwd,
                title: descriptor.title,
                modified: descriptor.modified
            )
            let trimmedTitle = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return NotesTreeNode(
                name: trimmedTitle.isEmpty ? descriptor.sessionId : descriptor.title,
                path: "cmux-virtual-session://\(descriptor.agent)/\(descriptor.sessionId)",
                kind: .sessionFolder(marker),
                isVirtual: true,
                children: []
            )
        }
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

    /// Add a session pointer as a real session folder in `folder` (or the
    /// workspace root). Used by drags (from the Vault, another Notes tree, or
    /// a virtual row) and by virtual-row materialization. Idempotent per
    /// sessionId — re-adding the same session reuses its folder. Returns the
    /// folder path. Only acted-on sessions get folders; the rest stay virtual,
    /// so the tree never floods the repo's `.cmux/notes` with empty dirs.
    @discardableResult
    func addSession(_ descriptor: NotesSessionDescriptor, intoFolder folder: String? = nil) -> String? {
        guard let target = try? ensureRoot(folder: folder) else { return nil }
        let path = NotesTreeStorage.createSessionFolder(inFolder: target, descriptor: descriptor)
        reload()
        refreshSessions()
        return path
    }

    /// Turn a virtual session row into a real session folder at the workspace
    /// root so notes can be filed under it (or content dropped into it).
    /// Returns the folder path. Idempotent per sessionId via `addSession`.
    @discardableResult
    func materializeSession(_ marker: NotesSessionMarker) -> String? {
        addSession(
            NotesSessionDescriptor(
                agent: marker.agent,
                sessionId: marker.sessionId,
                title: marker.title,
                cwd: marker.cwd,
                modified: marker.modified ?? 0
            )
        )
    }

    /// Refresh everything session-shaped from the live agent session stores —
    /// the same per-agent scanners the Vault uses. Two outputs per pass:
    /// `liveSessions` (the cwd's recent sessions, rendered as virtual rows) and
    /// rewritten `_session.json` markers for materialized folders whose session
    /// drifted (title/recency), wherever their cwd points. Scanning runs
    /// off-main; the tree reloads once when anything changed, which also
    /// re-sorts session rows by recency.
    func refreshSessions(force: Bool = false) {
        guard hasWorkspace, let root = resolvedRootPath, let cwd else { return }
        if !force, let last = lastMarkerRefresh,
           Date().timeIntervalSince(last) < markerRefreshMinInterval {
            return
        }
        guard markerRefreshTask == nil else { return }
        lastMarkerRefresh = Date()
        let workspaceCwd = (cwd as NSString).standardizingPath
        let limit = liveSessionLimit
        markerRefreshTask = Task { @MainActor [weak self] in
            defer { self?.markerRefreshTask = nil }
            let folders = await Task.detached(priority: .utility) {
                NotesTreeStorage.collectSessionFolders(inRoot: root)
            }.value
            guard !Task.isCancelled else { return }
            // The workspace cwd always gets scanned (it feeds the virtual
            // rows); dragged-in folders can point at other cwds, scan those
            // too so their markers stay fresh.
            var cwds: Set<String> = [workspaceCwd]
            for folder in folders {
                let markerCwd = (folder.marker.cwd as NSString).standardizingPath
                if !markerCwd.isEmpty { cwds.insert(markerCwd) }
            }
            var entriesByCwd: [String: [NotesSessionDescriptor]] = [:]
            for scanCwd in cwds.sorted() {
                guard !Task.isCancelled else { return }
                let entries = await SessionIndexStore.loadLiveSessionEntries(cwdFilter: scanCwd)
                entriesByCwd[scanCwd] = entries.map { entry in
                    NotesSessionDescriptor(
                        agent: entry.agent.rawValue,
                        sessionId: entry.sessionId,
                        title: entry.title,
                        cwd: entry.cwd ?? scanCwd,
                        modified: entry.modified.timeIntervalSince1970
                    )
                }
            }
            let allLive = entriesByCwd.values.flatMap { $0 }
            let markersChanged: Bool
            if folders.isEmpty || allLive.isEmpty {
                markersChanged = false
            } else {
                markersChanged = await Task.detached(priority: .utility) {
                    NotesTreeStorage.applySessionRefresh(folders: folders, live: allLive)
                }.value
            }
            guard !Task.isCancelled, let self, self.hasWorkspace,
                  let currentCwd = self.cwd,
                  (currentCwd as NSString).standardizingPath == workspaceCwd
            else { return }
            let recent = Array(
                (entriesByCwd[workspaceCwd] ?? [])
                    .sorted { $0.modified > $1.modified }
                    .prefix(limit)
            )
            let liveChanged = recent != self.liveSessions
            if liveChanged { self.liveSessions = recent }
            if markersChanged || liveChanged { self.reload() }
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

    /// Rename a note/folder in place. Confined to the project's `.cmux/notes`
    /// directory (which covers both the workspace subtree and the flat notes
    /// at its root). Carries the collapsed-state of the renamed subtree over
    /// to its new path so a rename doesn't visually re-expand everything
    /// beneath it. Returns the new path, or nil when the rename was rejected.
    @discardableResult
    func rename(path: String, toName newName: String) -> String? {
        guard isMutablePath(path) else { return nil }
        guard let renamed = try? NotesTreeStorage.rename(sourcePath: path, toName: newName) else {
            reload()
            return nil
        }
        let oldPrefix = (path as NSString).standardizingPath
        let newPrefix = (renamed as NSString).standardizingPath
        if oldPrefix != newPrefix {
            collapsedPaths = Set(collapsedPaths.map { collapsed in
                if collapsed == oldPrefix { return newPrefix }
                if collapsed.hasPrefix(oldPrefix + "/") {
                    return newPrefix + collapsed.dropFirst(oldPrefix.count)
                }
                return collapsed
            })
        }
        reload()
        return renamed
    }

    /// Move a note/folder to the system trash. Confined to the project's
    /// `.cmux/notes` directory so the tree can never delete outside the notes
    /// store.
    func delete(path: String) {
        guard isMutablePath(path) else { return }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        reload()
    }

    /// A path the tree may rename/delete: inside `.cmux/notes`, but never the
    /// notes directory itself nor the workspace's own root folder.
    private func isMutablePath(_ path: String) -> Bool {
        guard let notesDir = notesDirPath,
              NotesTreeStorage.isWithin(child: path, orEqualTo: notesDir) else { return false }
        let standardized = (path as NSString).standardizingPath
        if standardized == (notesDir as NSString).standardizingPath { return false }
        if let root = resolvedRootPath, standardized == (root as NSString).standardizingPath { return false }
        return true
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

    /// Collapse every directory in the tree (the header's Collapse All action).
    func collapseAll() {
        var dirs = Set<String>()
        collectDirectories(rootNodes, into: &dirs)
        guard !dirs.isEmpty else { return }
        collapsedPaths.formUnion(dirs)
        contentRevision &+= 1
    }

    /// Un-collapse every directory above `path` (including the workspace root
    /// row) so a freshly created/revealed item is actually visible after the
    /// next reload.
    func expandAncestors(ofPath path: String) {
        guard let root = resolvedRootPath else { return }
        let rootStandardized = (root as NSString).standardizingPath
        var current = ((path as NSString).standardizingPath as NSString).deletingLastPathComponent
        while NotesTreeStorage.isWithin(child: current, orEqualTo: rootStandardized) {
            collapsedPaths.remove(current)
            if current == rootStandardized { break }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    // MARK: - File watching

    /// Watch the workspace root, its nearest existing ancestor (so the root being
    /// created is observed), the flat-notes directory, and every directory in
    /// the tree, so external writes refresh the sidebar. Only rebuilds when the
    /// watched-directory set changes.
    private func refreshWatchers(forRoot root: String) {
        var dirs = Set<String>()
        dirs.insert(nearestExistingDirectory(of: root))
        if let notesDir = notesDirPath {
            dirs.insert(nearestExistingDirectory(of: notesDir))
        }
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

    /// Real directories only — virtual session rows have no on-disk path to
    /// watch or collapse.
    private func collectDirectories(_ nodes: [NotesTreeNode], into set: inout Set<String>) {
        for node in nodes where node.kind.isDirectory && !node.isVirtual {
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
        markerRefreshTask?.cancel()
    }
}
