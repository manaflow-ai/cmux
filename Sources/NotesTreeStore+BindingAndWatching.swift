import CmuxFoundation
import Foundation

extension NotesTreeStore {
    // MARK: - Workspace binding

    /// Bind the tree to a workspace, keyed by its persistent note anchor (with
    /// `currentDirectory` as the legacy fallback key). Passing a nil
    /// projectRoot/cwd (e.g. a remote workspace or no selection) clears the
    /// tree. Re-binding to the same workspace is a no-op; the
    /// `observedSessions` provider is refreshed either way.
    func setWorkspace(
        title: String,
        projectRoot: String?,
        currentDirectory: String?,
        anchorId: String? = nil,
        observedSessions: (() async -> NotesTreeObservation)? = nil
    ) {
        let cwd = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let projectRoot, let cwd, !cwd.isEmpty else {
            clear()
            return
        }
        let newRoot = NotesTreeStorage.resolveWorkspaceRoot(
            projectRoot: projectRoot, cwd: cwd, anchorId: anchorId
        )
        let unchanged = hasWorkspace
            && self.projectRoot == projectRoot
            && self.cwd == cwd
            && self.workspaceAnchorId == anchorId
            && resolvedRootPath == newRoot
        self.projectRoot = projectRoot
        self.workspaceTitle = title
        self.cwd = cwd
        self.workspaceAnchorId = anchorId
        self.observedSessionsProvider = observedSessions
        self.resolvedRootPath = newRoot
        self.notesDirPath = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        self.hasWorkspace = true
        self.headerDisplayPath = (cwd as NSString).abbreviatingWithTildeInPath
        guard !unchanged else { return }
        // A different workspace means the previous scan (if any) is stale:
        // cancel it and lift the throttle so the new workspace scans immediately.
        markerRefreshTask?.cancel()
        markerRefreshTask = nil
        cancelPendingReload()
        emptyObservationRetryTask?.cancel()
        emptyObservationRetryTask = nil
        lastMarkerRefresh = nil
        emptyObservationRetries = 0
        observedTerminals = []
        observedSessionKeys = []
        self.observedSessions = []
        reload()
        refreshSessions()
    }

    /// Detach from any workspace and empty the tree (remote/no-selection state).
    func clear() {
        guard hasWorkspace || !rootNodes.isEmpty || reloadTask != nil else { return }
        stopWatchers()
        cancelPendingReload()
        reloadCoalesceTask?.cancel()
        reloadCoalesceTask = nil
        markerRefreshTask?.cancel()
        markerRefreshTask = nil
        emptyObservationRetryTask?.cancel()
        emptyObservationRetryTask = nil
        visibilityRefreshTask?.cancel()
        visibilityRefreshTask = nil
        lastMarkerRefresh = nil
        hasWorkspace = false
        projectRoot = nil
        cwd = nil
        workspaceAnchorId = nil
        observedSessionsProvider = nil
        resolvedRootPath = nil
        notesDirPath = nil
        observedTerminals = []
        observedSessionKeys = []
        observedSessions = []
        rootNodes = []
        headerDisplayPath = ""
        contentRevision &+= 1
    }

    /// Adopt the latest terminal-pane observation; reloads when it changed.
    /// Called from the session-refresh pass (and tests).
    func applyObservedTerminals(_ terminals: [NotesTreeObservedTerminal]) {
        guard terminals != observedTerminals else { return }
        observedTerminals = terminals
        reload()
    }

    /// Adopt the latest live pane-session observation; reloads when it changed.
    /// Historical workspace records remain on disk, but are not presented as
    /// current session rows unless the pane observation still sees them.
    func applyObservedSessions(_ sessions: [NotesTreeObservedSession]) {
        guard updateObservedSessionKeys(sessions: sessions) else { return }
        reload()
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

    /// While the Notes tab is visible, re-scan this workspace's sessions on a
    /// short cadence so agents launched while the tab is open appear without
    /// switching away and back. Cheap when nothing changed — the pass only
    /// reloads on diffs. Only a timer is scheduled here; no published state
    /// is touched (the appear/disappear reload feedback loop class).
    func setVisible(_ visible: Bool) {
        if visible {
            guard visibilityRefreshTask == nil else { return }
            visibilityRefreshTask = Task { @MainActor [weak self, clock] in
                while !Task.isCancelled {
                    try? await clock.sleep(for: .seconds(10))
                    guard let self else { break }
                    guard self.hasWorkspace, !Task.isCancelled else { continue }
                    self.refreshSessions(force: true)
                }
            }
        } else {
            visibilityRefreshTask?.cancel()
            visibilityRefreshTask = nil
        }
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
        Self.collectDirectories(rootNodes, into: &dirs)
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
    static func watcherDirectories(
        root: String,
        notesDirPath: String?,
        nodes: [NotesTreeNode],
        maxWatchers: Int
    ) -> Set<String> {
        var dirs = Set<String>()
        dirs.insert(nearestExistingDirectory(of: root))
        if let notesDirPath {
            dirs.insert(nearestExistingDirectory(of: notesDirPath))
        }
        collectDirectories(nodes, into: &dirs)
        if dirs.count > maxWatchers {
            // Defensive cap: prefer the shallowest paths.
            dirs = Set(dirs.sorted { $0.count < $1.count }.prefix(maxWatchers))
        }
        return dirs
    }

    func refreshWatchers(forDirectories dirs: Set<String>) {
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
    private static func collectDirectories(_ nodes: [NotesTreeNode], into set: inout Set<String>) {
        for node in nodes where node.kind.isDirectory && !node.isVirtual {
            set.insert(node.path)
            if let children = node.children { collectDirectories(children, into: &set) }
        }
    }

    private static func nearestExistingDirectory(of path: String) -> String {
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

    func cancelPendingReload() {
        reloadGeneration &+= 1
        reloadTask?.cancel()
        reloadTask = nil
    }

    func stopWatchers() {
        for task in watcherTasks { task.cancel() }
        watcherTasks = []
        watchers = []
        watchedDirs = []
    }
}
