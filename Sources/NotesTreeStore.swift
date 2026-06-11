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
    /// The workspace's persistent note anchor — the identity the folder,
    /// flat-note filter, and session records are keyed by, so same-cwd
    /// workspaces never blend together.
    private var workspaceAnchorId: String?
    /// Supplies the agent sessions currently known to run in this workspace's
    /// panes (live snapshots, the shared restorable-agent index, and the
    /// pane-TTY process pass). Injected by the composition root; starts on the
    /// main actor and may suspend for the process lookup.
    private var observedSessionsProvider: (() async -> NotesTreeObservation)?
    /// Absolute path to `<projectRoot>/.cmux/notes/<workspace-folder>` (resolved,
    /// not necessarily created yet — materialized on first mutation/sync).
    private(set) var resolvedRootPath: String?
    /// Absolute path to `<projectRoot>/.cmux/notes` — the flat-note directory
    /// shared by the project, and the confinement boundary for tree mutations.
    private(set) var notesDirPath: String?
    /// Cap on session rows so a long-lived workspace doesn't flood the sidebar.
    private let sessionRowLimit = 20

    /// Paths the user has explicitly collapsed. Everything is expanded by
    /// default; only entries listed here stay collapsed across reloads.
    private var collapsedPaths: Set<String> = []

    private var watchers: [FileWatcher] = []
    private var watcherTasks: [Task<Void, Never>] = []
    private var watchedDirs: Set<String> = []
    private var reloadCoalesceTask: Task<Void, Never>?
    private var markerRefreshTask: Task<Void, Never>?
    private var visibilityRefreshTask: Task<Void, Never>?
    private var emptyObservationRetryTask: Task<Void, Never>?
    private var lastMarkerRefresh: Date?
    /// Floor between appear-triggered marker refreshes; Refresh bypasses it.
    private let markerRefreshMinInterval: TimeInterval = 30
    /// Consecutive refresh passes that observed no pane sessions. The shared
    /// agent index loads asynchronously (seconds), so an early pass can see
    /// nothing; a few spaced retries keep the tab from sticking empty until
    /// the next appear.
    private var emptyObservationRetries = 0
    private let maxEmptyObservationRetries = 3

    private let maxDepth = 12
    private let nodeBudget = 5000
    private let maxWatchers = 256

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
        emptyObservationRetryTask?.cancel()
        emptyObservationRetryTask = nil
        lastMarkerRefresh = nil
        emptyObservationRetries = 0
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
        emptyObservationRetryTask?.cancel()
        emptyObservationRetryTask = nil
        lastMarkerRefresh = nil
        hasWorkspace = false
        projectRoot = nil
        cwd = nil
        workspaceAnchorId = nil
        observedSessionsProvider = nil
        resolvedRootPath = nil
        notesDirPath = nil
        rootNodes = []
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

    /// While the Notes tab is visible, re-scan this workspace's sessions on a
    /// short cadence so agents launched while the tab is open appear without
    /// switching away and back. Cheap when nothing changed — the pass only
    /// reloads on diffs. Only a timer is scheduled here; no published state
    /// is touched (the appear/disappear reload feedback loop class).
    func setVisible(_ visible: Bool) {
        if visible {
            guard visibilityRefreshTask == nil else { return }
            visibilityRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
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

    // MARK: - Loading

    /// Rebuild the full node tree and refresh file watchers. The top level is
    /// the union the Notes tab presents for THIS workspace: the workspace
    /// folder's own contents, the workspace's flat notes (index.json records
    /// attached to its note anchor), and the sessions recorded as having run
    /// in its panes — virtual rows unless a materialized folder exists. Flat
    /// notes whose pane maps to a recorded session nest under that session's
    /// row.
    func reload() {
        // A symlinked `.cmux`/`.cmux/notes` re-roots every path below it;
        // refuse to render (or later mutate) such a tree at all.
        if let projectRoot, !NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) {
            rootNodes = []
            contentRevision &+= 1
            return
        }
        guard let root = resolvedRootPath, !NotesTreeStorage.isSymlink(root) else {
            rootNodes = []
            contentRevision &+= 1
            return
        }
        var budget = nodeBudget
        var nodes = buildChildren(ofDirectory: root, depth: 0, budget: &budget)
        let records = NotesTreeStorage.readWorkspaceSessions(inRoot: root)
        nodes.append(contentsOf: sessionRowNodes(records: records, materializedInto: nodes))

        // Session lookup for nesting (virtual rows + materialized folders).
        var sessionNodeById: [String: NotesTreeNode] = [:]
        func indexSessions(_ nodes: [NotesTreeNode]) {
            for node in nodes {
                if let marker = node.kind.sessionMarker { sessionNodeById[marker.sessionId] = node }
                if let children = node.children { indexSessions(children) }
            }
        }
        indexSessions(nodes)
        var sessionIdBySurfaceAnchor: [String: String] = [:]
        for record in records {
            if let anchor = record.surfaceAnchorId { sessionIdBySurfaceAnchor[anchor] = record.sessionId }
        }

        // This workspace's flat notes: nested under their pane's session when
        // known, top-level otherwise.
        if let projectRoot, let anchorId = workspaceAnchorId {
            for ref in NotesTreeStorage.listIndexedNotes(projectRoot: projectRoot, workspaceAnchorId: anchorId) {
                // A flat note whose body was moved INSIDE the workspace folder
                // is already listed as a real file; skip the index ref so the
                // note doesn't appear twice.
                guard !NotesTreeStorage.isWithin(child: ref.path, orEqualTo: root) else { continue }
                let node = NotesTreeNode(name: ref.title, path: ref.path, kind: .note)
                if let anchor = ref.surfaceAnchorId,
                   let sessionId = sessionIdBySurfaceAnchor[anchor],
                   let sessionNode = sessionNodeById[sessionId] {
                    sessionNode.children = (sessionNode.children ?? []) + [node]
                } else {
                    nodes.append(node)
                }
            }
        }

        for sessionNode in sessionNodeById.values {
            sessionNode.children?.sort(by: nodeDisplayOrder)
        }
        nodes.sort(by: nodeDisplayOrder)
        rootNodes = nodes
        contentRevision &+= 1
        refreshWatchers(forRoot: root)
    }

    private func nodeDisplayOrder(_ lhs: NotesTreeNode, _ rhs: NotesTreeNode) -> Bool {
        NotesTreeStorage.displayOrder(
            NotesTreeEntry(name: lhs.name, path: lhs.path, kind: lhs.kind),
            NotesTreeEntry(name: rhs.name, path: rhs.path, kind: rhs.kind)
        )
    }

    /// Rows for the workspace's recorded sessions that have no materialized
    /// folder yet (those appear as their folder node instead).
    private func sessionRowNodes(
        records: [NotesWorkspaceSessionRecord],
        materializedInto nodes: [NotesTreeNode]
    ) -> [NotesTreeNode] {
        guard !records.isEmpty else { return [] }
        var materializedIds = Set<String>()
        func collect(_ nodes: [NotesTreeNode]) {
            for node in nodes {
                if let marker = node.kind.sessionMarker { materializedIds.insert(marker.sessionId) }
                if let children = node.children { collect(children) }
            }
        }
        collect(nodes)
        return records.prefix(sessionRowLimit).compactMap { record in
            guard !materializedIds.contains(record.sessionId) else { return nil }
            let marker = NotesSessionMarker(
                agent: record.agent,
                sessionId: record.sessionId,
                cwd: record.cwd,
                title: record.title,
                modified: record.modified
            )
            let trimmedTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return NotesTreeNode(
                name: trimmedTitle.isEmpty ? record.sessionId : record.title,
                path: "cmux-virtual-session://\(record.agent)/\(record.sessionId)",
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

    /// Refresh everything session-shaped. Per pass:
    /// 1. Observe the agent sessions currently known to this workspace's
    ///    panes (injected provider) and upsert them into the marker's session
    ///    records — that is what scopes the tab to THIS workspace instead of
    ///    every session sharing the directory.
    /// 2. Scan the live agent session stores (the Vault's scanners) for the
    ///    involved cwds and hydrate record + materialized-folder metadata
    ///    (titles, recency).
    /// Scanning runs off-main; the tree reloads once when anything changed,
    /// which also re-sorts session rows by recency.
    func refreshSessions(force: Bool = false) {
        guard hasWorkspace, let cwd else { return }
        if !force, let last = lastMarkerRefresh,
           Date().timeIntervalSince(last) < markerRefreshMinInterval {
            return
        }
        guard markerRefreshTask == nil else { return }
        lastMarkerRefresh = Date()
        let workspaceCwd = (cwd as NSString).standardizingPath
        let provider = observedSessionsProvider
        guard let root = resolvedRootPath else { return }
        markerRefreshTask = Task { @MainActor [weak self] in
            defer { self?.markerRefreshTask = nil }
            let observation = await provider?() ?? NotesTreeObservation()
            let observed = observation.sessions
            // Observations need the workspace folder + marker on disk to
            // persist into; materialize it lazily the first time this
            // workspace actually runs an agent (one small folder — not the
            // per-session flood the old auto-materialization caused).
            if !observed.isEmpty || !observation.anonymousAgents.isEmpty {
                _ = try? self?.ensureRoot(folder: nil)
            }
            let folders = await Task.detached(priority: .utility) {
                NotesTreeStorage.collectSessionFolders(inRoot: root)
            }.value
            guard !Task.isCancelled else { return }
            // Scan the workspace cwd (hydrates observed/recorded sessions)
            // plus any cwd a recorded session or dragged-in folder points at.
            var cwds: Set<String> = [workspaceCwd]
            for folder in folders {
                let markerCwd = (folder.marker.cwd as NSString).standardizingPath
                if !markerCwd.isEmpty { cwds.insert(markerCwd) }
            }
            for record in NotesTreeStorage.readWorkspaceSessions(inRoot: root) {
                let recordCwd = (record.cwd as NSString).standardizingPath
                if !recordCwd.isEmpty { cwds.insert(recordCwd) }
            }
            var live: [NotesSessionDescriptor] = []
            for scanCwd in cwds.sorted() {
                guard !Task.isCancelled else { return }
                let entries = await SessionIndexStore.loadLiveSessionEntries(cwdFilter: scanCwd)
                live.append(contentsOf: entries.map { entry in
                    NotesSessionDescriptor(
                        agent: entry.agent.rawValue,
                        sessionId: entry.sessionId,
                        title: entry.title,
                        cwd: entry.cwd ?? scanCwd,
                        modified: entry.modified.timeIntervalSince1970
                    )
                })
            }
            let now = Date().timeIntervalSince1970
            let liveSnapshot = live
            // The shared agent index refreshes asynchronously (1s TTL); the
            // scans above bought it time, so re-pull observations to catch
            // panes a cold first pass missed.
            let lateObservation = await provider?() ?? NotesTreeObservation()
            let lateObserved = lateObservation.sessions
            // Hookless agents (bare launches that bypassed the wrapper):
            // resolve each agent-on-a-pane-TTY to the workspace cwd's newest
            // session of that agent that has been active since the process
            // started — the same inference a human makes in the Vault.
            let anonymous = observation.anonymousAgents + lateObservation.anonymousAgents
            var resolvedAnonymous: [NotesTreeObservedSession] = []
            if !anonymous.isEmpty {
                var taken = Set<String>()
                let cwdLive = liveSnapshot
                    .filter { ($0.cwd as NSString).standardizingPath == workspaceCwd }
                    .sorted { $0.modified > $1.modified }
                for anon in anonymous {
                    // 120s slack: a just-resumed session's file mtime can
                    // slightly predate the process start.
                    if let match = cwdLive.first(where: { candidate in
                        candidate.agent == anon.agent
                            && candidate.modified >= anon.startedAt - 120
                            && !taken.contains("\(candidate.agent)\n\(candidate.sessionId)")
                    }) {
                        taken.insert("\(match.agent)\n\(match.sessionId)")
                        resolvedAnonymous.append(NotesTreeObservedSession(
                            agent: match.agent, sessionId: match.sessionId, surfaceAnchorId: nil
                        ))
                    }
                }
            }
            let allObserved = observed + lateObserved + resolvedAnonymous
            if !allObserved.isEmpty, observed.isEmpty {
                _ = try? self?.ensureRoot(folder: nil)
            }
            let changed = await Task.detached(priority: .utility) {
                var changed = false
                if !folders.isEmpty, !liveSnapshot.isEmpty {
                    changed = NotesTreeStorage.applySessionRefresh(folders: folders, live: liveSnapshot)
                }
                if NotesTreeStorage.updateWorkspaceSessions(
                    inRoot: root, observed: allObserved, live: liveSnapshot, now: now
                ) {
                    changed = true
                }
                return changed
            }.value
            guard !Task.isCancelled, let self, self.hasWorkspace,
                  self.resolvedRootPath == root
            else { return }
            #if DEBUG
            cmuxDebugLog(
                "notes.refresh observed=\(observed.count) late=\(lateObserved.count) "
                + "anon=\(anonymous.count) anonResolved=\(resolvedAnonymous.count) "
                + "folders=\(folders.count) live=\(liveSnapshot.count) changed=\(changed) "
                + "records=\(NotesTreeStorage.readWorkspaceSessions(inRoot: root).count)"
            )
            #endif
            if changed { self.reload() }
            if allObserved.isEmpty, self.emptyObservationRetries < self.maxEmptyObservationRetries {
                self.emptyObservationRetries += 1
                self.emptyObservationRetryTask?.cancel()
                self.emptyObservationRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled,
                          self.hasWorkspace, self.resolvedRootPath == root else { return }
                    self.refreshSessions(force: true)
                }
            } else if !allObserved.isEmpty {
                self.emptyObservationRetries = 0
            }
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
    /// on failure (e.g. invalid move). Both endpoints must lie inside
    /// `.cmux/notes`: the move pasteboard type is globally forgeable, so a
    /// crafted drag payload must never be able to relocate arbitrary
    /// user-writable files into (or around) the project.
    @discardableResult
    func move(sourcePath: String, intoFolder destinationFolder: String) -> String? {
        guard isMutablePath(sourcePath),
              let notesDir = notesDirPath,
              NotesTreeStorage.isWithin(child: destinationFolder, orEqualTo: notesDir)
        else { return nil }
        let moved = try? NotesTreeStorage.move(sourcePath: sourcePath, intoFolder: destinationFolder)
        if let moved {
            rebaseIndexedBodies(from: sourcePath, to: moved)
            postRelocation(from: sourcePath, to: moved)
        }
        reload()
        return moved
    }

    /// Keep `index.json` pointing at bodies a raw tree move/rename relocated.
    /// An indexed note that was filed into the tree (or a folder containing
    /// one) moves with plain FileManager calls; without the rebase its index
    /// record silently orphans and `cmux note read/open` loses the note.
    private func rebaseIndexedBodies(from oldPath: String, to newPath: String) {
        guard let projectRoot else { return }
        try? CmuxNoteStore.rebaseBodyPaths(
            projectRoot: projectRoot, fromAbsolutePath: oldPath, toAbsolutePath: newPath
        )
    }

    /// Announce a completed on-disk relocation so open viewers (markdown
    /// panels on the moved note, or on notes inside a moved/renamed folder)
    /// re-point at the new path instead of going "File unavailable".
    private func postRelocation(from oldPath: String, to newPath: String) {
        let old = (oldPath as NSString).standardizingPath
        let new = (newPath as NSString).standardizingPath
        guard old != new else { return }
        NotificationCenter.default.post(
            name: .cmuxNoteFileRelocated,
            object: nil,
            userInfo: ["oldPath": old, "newPath": new]
        )
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
        rebaseIndexedBodies(from: oldPrefix, to: newPrefix)
        postRelocation(from: oldPrefix, to: newPrefix)
        reload()
        return renamed
    }

    /// Move a note/folder to the system trash. Confined to the project's
    /// `.cmux/notes` directory so the tree can never delete outside the notes
    /// store.
    func delete(path: String) {
        guard isMutablePath(path) else { return }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        // Indexed notes whose body just went to the Trash (directly, or via a
        // trashed ancestor folder) must leave the index with it.
        if let projectRoot {
            try? CmuxNoteStore.removeRecords(underAbsolutePath: path, projectRoot: projectRoot)
        }
        reload()
    }

    /// Move an index-owned flat note into `destinationFolder` through the flat
    /// store, which relocates the body AND rewrites the index's bodyPath in
    /// one transaction (a bare file move would orphan the record). Returns the
    /// new path.
    @discardableResult
    func moveFlatNote(path: String, intoFolder destinationFolder: String) -> String? {
        guard let projectRoot,
              let notesDir = notesDirPath,
              NotesTreeStorage.isWithin(child: destinationFolder, orEqualTo: notesDir),
              let records = try? CmuxNoteStore.list(projectRoot: projectRoot) else { return nil }
        let target = (path as NSString).standardizingPath
        guard let record = records.first(where: {
            (CmuxNoteStore.noteBodyPath(for: $0, projectRoot: projectRoot) as NSString)
                .standardizingPath == target
        }) else { return nil }
        let moved = try? CmuxNoteStore.relocateBody(
            slug: record.slug, projectRoot: projectRoot, toDirectory: destinationFolder
        )
        if let moved { postRelocation(from: target, to: moved) }
        reload()
        return moved
    }

    /// Delete an index-owned flat note through the flat store so the body and
    /// its index record/attachments go together — trashing only the body file
    /// would leave `cmux note list` showing a note whose `read` fails.
    func deleteFlatNote(path: String) {
        guard let projectRoot,
              let records = try? CmuxNoteStore.list(projectRoot: projectRoot) else { return }
        let target = (path as NSString).standardizingPath
        if let record = records.first(where: {
            (CmuxNoteStore.noteBodyPath(for: $0, projectRoot: projectRoot) as NSString)
                .standardizingPath == target
        }) {
            _ = try? CmuxNoteStore.delete(slug: record.slug, projectRoot: projectRoot)
        }
        reload()
    }

    /// A path the tree may rename/delete: inside `.cmux/notes`, but never the
    /// notes directory itself nor the workspace's own root folder.
    private func isMutablePath(_ path: String) -> Bool {
        if let projectRoot, !NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) {
            return false
        }
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
            projectRoot: projectRoot, cwd: cwd, title: workspaceTitle, anchorId: workspaceAnchorId
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
        visibilityRefreshTask?.cancel()
        emptyObservationRetryTask?.cancel()
    }
}
