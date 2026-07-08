import CmuxFoundation
import Foundation
import Observation
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
@Observable
final class NotesTreeStore {
    /// Top-level nodes (children of the workspace notes root).
    private(set) var rootNodes: [NotesTreeNode] = []
    /// Bumped on every structural reload so the outline view reloads its data.
    private(set) var contentRevision = 0
    /// Whether a local workspace is currently bound (false ⇒ empty/disabled tree).
    private(set) var hasWorkspace = false
    /// Abbreviated workspace path shown in the header bar — the same treatment
    /// as the Files tab's header (cwd with the home directory as `~`). Changes
    /// only when the bound cwd changes, which always reloads the tree.
    private(set) var headerDisplayPath = ""

    var projectRoot: String?
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
    /// Per-cwd live-session scan cap for the visible-sidebar refresh cadence.
    private var liveSessionEntryLimit: Int { max(sessionRowLimit * 2, 30) }

    /// Paths the user has explicitly collapsed. Everything is expanded by
    /// default; only entries listed here stay collapsed across reloads.
    private var collapsedPaths: Set<String> = []

    /// The workspace's live terminal panes from the latest observation pass.
    /// Each becomes a virtual folder row pointing back at its panel, with the
    /// pane's attached flat notes nested beneath it.
    private(set) var observedTerminals: [NotesTreeObservedTerminal] = []
    /// Agent sessions from the latest live pane observation. Workspace markers
    /// keep historical records for hydration/restore, but virtual session rows
    /// should only reflect sessions currently present in workspace panes.
    private var observedSessionKeys: Set<String> = []
    /// Full live pane-session observations from the latest pass. `observedSessionKeys`
    /// is the persistence/display filter; this keeps the panel/anchor pointer
    /// needed to render a terminal row as its currently running agent.
    private var observedSessions: [NotesTreeObservedSession] = []

    private var watchers: [FileWatcher] = []
    private var watcherTasks: [Task<Void, Never>] = []
    private var watchedDirs: Set<String> = []
    /// Internal (not private) so tests can await the pending reload via
    /// `@testable import` without a production test hook.
    private(set) var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var reloadCoalesceTask: Task<Void, Never>?
    private var markerRefreshTask: Task<Void, Never>?
    private var visibilityRefreshTask: Task<Void, Never>?
    private var emptyObservationRetryTask: Task<Void, Never>?
    private var lastMarkerRefresh: Date?
    /// Rotation cursor for the bounded foreign-cwd live-session scans.
    private var liveScanRotation = 0
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
    /// Clock backing the coalesce/retry/poll waits below, so timed waits are
    /// cancellable and expressed via the injected-clock idiom rather than
    /// bare task sleeps.
    private let clock = ContinuousClock()

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

    // MARK: - Loading

    /// Rebuild the full node tree and refresh file watchers. The top level is
    /// the union the Notes tab presents for THIS workspace: the workspace
    /// folder's own contents, the workspace's flat notes (index.json records
    /// attached to its note anchor), live terminal panes, and sessions
    /// currently observed in those panes. Historical session records remain on
    /// disk for hydration/restore but do not create current rows by themselves.
    func reload() {
        // A symlinked `.cmux`/`.cmux/notes` re-roots every path below it;
        // refuse to render (or later mutate) such a tree at all.
        guard let root = resolvedRootPath, currentRootIsTrusted(root) else {
            cancelPendingReload()
            clearRenderedRoot()
            return
        }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let request = NotesTreeReloadRequest(
            root: root,
            notesDirPath: notesDirPath,
            projectRoot: projectRoot,
            workspaceAnchorId: workspaceAnchorId,
            observedTerminals: observedTerminals,
            observedSessionKeys: observedSessionKeys,
            observedSessions: observedSessions,
            maxDepth: maxDepth,
            nodeBudget: nodeBudget,
            sessionRowLimit: sessionRowLimit,
            maxWatchers: maxWatchers
        )
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            let buildTask = Task.detached(priority: .utility) {
                Self.buildReloadResult(request)
            }
            let result = await withTaskCancellationHandler {
                await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard let self else { return }
            defer {
                if self.reloadGeneration == generation {
                    self.reloadTask = nil
                }
            }
            guard let result else { return }
            guard !Task.isCancelled, self.reloadGeneration == generation else { return }
            guard self.hasWorkspace,
                  self.resolvedRootPath == root,
                  self.currentRootIsTrusted(root)
            else {
                self.clearRenderedRootIfCurrent(root)
                return
            }
            self.rootNodes = result.nodes
            self.contentRevision &+= 1
            self.refreshWatchers(forDirectories: result.watchedDirs)
        }
    }

    private static func buildReloadResult(_ request: NotesTreeReloadRequest) -> NotesTreeReloadResult? {
        guard !Task.isCancelled else { return nil }
        let indexedRefs = request.projectRoot.flatMap { projectRoot in
            request.workspaceAnchorId.map {
                NotesTreeStorage.listIndexedNotes(projectRoot: projectRoot, workspaceAnchorId: $0)
            }
        } ?? []
        guard !Task.isCancelled else { return nil }
        let indexedTitleByPath = Dictionary(
            indexedRefs.map { (($0.path as NSString).standardizingPath, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        var budget = request.nodeBudget
        var nodes = buildChildren(
            ofDirectory: request.root,
            depth: 0,
            maxDepth: request.maxDepth,
            budget: &budget,
            indexedTitleByPath: indexedTitleByPath
        )
        guard !Task.isCancelled else { return nil }
        let records = NotesTreeStorage.readWorkspaceSessions(inRoot: request.root)
        guard !Task.isCancelled else { return nil }
        nodes.append(contentsOf: sessionRowNodes(
            records: records,
            materializedInto: nodes,
            visibleSessionKeys: request.observedSessionKeys,
            sessionRowLimit: request.sessionRowLimit
        ))
        let pastSessionRows = pastSessionRowNodes(
            records: records,
            materializedInto: nodes,
            visibleSessionKeys: request.observedSessionKeys,
            sessionRowLimit: request.sessionRowLimit
        )
        let activeSessionByTerminal = terminalActiveSessions(
            records: records,
            observations: request.observedSessions
        )

        // Terminal rows: every live terminal pane, in pane order, as a virtual
        // folder pointing back at its panel. Built before nesting so anchored
        // notes and current sessions can land beneath the terminal that owns
        // them.
        var terminalNodeByAnchor: [String: NotesTreeNode] = [:]
        let terminalNodes = request.observedTerminals.map { terminal in
            var terminal = terminal
            if let active = activeSessionByTerminal[terminal.panelId]
                ?? terminal.anchorId.flatMap({ activeSessionByTerminal[$0] }) {
                terminal.activeSession = active
            } else {
                terminal.activeSession = nil
            }
            let node = NotesTreeNode(
                name: terminal.title,
                path: "cmux-virtual-terminal://\(terminal.panelId)",
                kind: .terminalFolder(terminal),
                isVirtual: true,
                children: []
            )
            if let anchor = terminal.anchorId { terminalNodeByAnchor[anchor] = node }
            return node
        }

        // A VIRTUAL session row from the latest live observation nests under
        // that terminal — "claude running in this pane" sits beneath the pane.
        // Materialized user-created session folders keep their real disk
        // position.
        if !terminalNodeByAnchor.isEmpty {
            var anchorBySessionKey: [String: String] = [:]
            for record in records {
                if let anchor = record.surfaceAnchorId {
                    anchorBySessionKey[Self.sessionKey(agent: record.agent, sessionId: record.sessionId)] = anchor
                }
            }
            nodes.removeAll { node in
                guard node.isVirtual,
                      let marker = node.kind.sessionMarker,
                      let anchor = anchorBySessionKey[Self.sessionKey(agent: marker.agent, sessionId: marker.sessionId)],
                      let terminalNode = terminalNodeByAnchor[anchor] else { return false }
                if let activeSession = terminalNode.kind.terminalMarker?.activeSession,
                   Self.sessionKey(agent: activeSession.agent, sessionId: activeSession.sessionId) ==
                    Self.sessionKey(agent: marker.agent, sessionId: marker.sessionId) {
                    return true
                }
                terminalNode.children = (terminalNode.children ?? []) + [node]
                return true
            }
        }
        nodes.append(contentsOf: terminalNodes)
        if !pastSessionRows.isEmpty {
            nodes.append(NotesTreeNode(
                name: "past",
                path: "cmux-virtual-past://\(request.workspaceAnchorId ?? request.root)",
                kind: .pastFolder,
                isVirtual: true,
                children: pastSessionRows.sorted(by: nodeDisplayOrder)
            ))
        }

        // Session lookup for nesting (virtual rows + materialized folders),
        // including rows already moved under a terminal.
        var sessionNodeByKey: [String: NotesTreeNode] = [:]
        func indexSessions(_ nodes: [NotesTreeNode]) {
            for node in nodes {
                if let marker = node.kind.sessionMarker {
                    sessionNodeByKey[Self.sessionKey(agent: marker.agent, sessionId: marker.sessionId)] = node
                }
                if let children = node.children { indexSessions(children) }
            }
        }
        indexSessions(nodes)
        var sessionKeyBySurfaceAnchor: [String: String] = [:]
        for record in records {
            if let anchor = record.surfaceAnchorId {
                sessionKeyBySurfaceAnchor[anchor] = Self.sessionKey(agent: record.agent, sessionId: record.sessionId)
            }
        }

        // This workspace's flat notes: nested under their pane's live terminal
        // when one matches, else under the pane's currently observed session,
        // top-level last.
        if !indexedRefs.isEmpty {
            for ref in indexedRefs {
                // A flat note whose body was moved INSIDE the workspace folder
                // is already listed as a real file; skip the index ref so the
                // note doesn't appear twice.
                guard !NotesTreeStorage.isWithin(child: ref.path, orEqualTo: request.root) else { continue }
                let node = NotesTreeNode(name: ref.title, path: ref.path, kind: .note)
                if let anchor = ref.surfaceAnchorId,
                   let terminalNode = terminalNodeByAnchor[anchor],
                   let activeSession = terminalNode.kind.terminalMarker?.activeSession,
                   sessionKeyBySurfaceAnchor[anchor] == Self.sessionKey(
                        agent: activeSession.agent,
                        sessionId: activeSession.sessionId
                   ) {
                    terminalNode.children = (terminalNode.children ?? []) + [node]
                } else if let anchor = ref.surfaceAnchorId,
                          let sessionKey = sessionKeyBySurfaceAnchor[anchor],
                          let sessionNode = sessionNodeByKey[sessionKey] {
                    sessionNode.children = (sessionNode.children ?? []) + [node]
                } else if let anchor = ref.surfaceAnchorId,
                          let terminalNode = terminalNodeByAnchor[anchor] {
                    terminalNode.children = (terminalNode.children ?? []) + [node]
                } else {
                    nodes.append(node)
                }
            }
        }

        for sessionNode in sessionNodeByKey.values {
            sessionNode.children?.sort(by: nodeDisplayOrder)
        }
        for terminalNode in terminalNodes {
            terminalNode.children?.sort(by: nodeDisplayOrder)
        }
        // Terminals keep pane order (the order they sit in the workspace),
        // not name order; everything else uses the standard display order.
        let terminalPaneOrder: [String: Int] = Dictionary(
            uniqueKeysWithValues: request.observedTerminals.enumerated().map { ($0.element.panelId, $0.offset) }
        )
        nodes.sort { lhs, rhs in
            if let lhsTerminal = lhs.kind.terminalMarker, let rhsTerminal = rhs.kind.terminalMarker {
                return (terminalPaneOrder[lhsTerminal.panelId] ?? 0)
                    < (terminalPaneOrder[rhsTerminal.panelId] ?? 0)
            }
            return nodeDisplayOrder(lhs, rhs)
        }
        guard !Task.isCancelled else { return nil }
        return NotesTreeReloadResult(
            nodes: nodes,
            watchedDirs: watcherDirectories(
                root: request.root,
                notesDirPath: request.notesDirPath,
                nodes: nodes,
                maxWatchers: request.maxWatchers
            )
        )
    }

    private static func nodeDisplayOrder(_ lhs: NotesTreeNode, _ rhs: NotesTreeNode) -> Bool {
        NotesTreeStorage.displayOrder(
            NotesTreeEntry(name: lhs.name, path: lhs.path, kind: lhs.kind),
            NotesTreeEntry(name: rhs.name, path: rhs.path, kind: rhs.kind)
        )
    }

    /// Rows for currently observed workspace sessions that have no
    /// user-created materialized folder yet.
    private static func sessionRowNodes(
        records: [NotesWorkspaceSessionRecord],
        materializedInto nodes: [NotesTreeNode],
        visibleSessionKeys: Set<String>,
        sessionRowLimit: Int
    ) -> [NotesTreeNode] {
        guard !records.isEmpty, !visibleSessionKeys.isEmpty else { return [] }
        var materializedKeys = Set<String>()
        func collect(_ nodes: [NotesTreeNode]) {
            for node in nodes {
                if let marker = node.kind.sessionMarker {
                    materializedKeys.insert(Self.sessionKey(agent: marker.agent, sessionId: marker.sessionId))
                }
                if let children = node.children { collect(children) }
            }
        }
        collect(nodes)
        return records
            .filter { visibleSessionKeys.contains(Self.sessionKey(agent: $0.agent, sessionId: $0.sessionId)) }
            .prefix(sessionRowLimit)
            .compactMap { record in
                guard !materializedKeys.contains(Self.sessionKey(agent: record.agent, sessionId: record.sessionId))
                else { return nil }
                let marker = NotesSessionMarker(
                    agent: record.agent,
                    sessionId: record.sessionId,
                    cwd: record.cwd,
                    title: record.title,
                    modified: record.modified,
                    userCreated: nil
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

    /// Rows for previously observed sessions. These are grouped under the
    /// virtual Past folder after they are no longer present in a live terminal,
    /// preserving the workspace's context without deleting or moving note files.
    private static func pastSessionRowNodes(
        records: [NotesWorkspaceSessionRecord],
        materializedInto nodes: [NotesTreeNode],
        visibleSessionKeys: Set<String>,
        sessionRowLimit: Int
    ) -> [NotesTreeNode] {
        guard !records.isEmpty else { return [] }
        var materializedKeys = Set<String>()
        func collect(_ nodes: [NotesTreeNode]) {
            for node in nodes {
                if let marker = node.kind.sessionMarker {
                    materializedKeys.insert(Self.sessionKey(agent: marker.agent, sessionId: marker.sessionId))
                }
                if let children = node.children { collect(children) }
            }
        }
        collect(nodes)
        return records
            .filter { !visibleSessionKeys.contains(Self.sessionKey(agent: $0.agent, sessionId: $0.sessionId)) }
            .prefix(sessionRowLimit)
            .compactMap { record in
                guard !materializedKeys.contains(Self.sessionKey(agent: record.agent, sessionId: record.sessionId))
                else { return nil }
                let marker = NotesSessionMarker(
                    agent: record.agent,
                    sessionId: record.sessionId,
                    cwd: record.cwd,
                    title: record.title,
                    modified: record.modified,
                    userCreated: nil
                )
                let trimmedTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return NotesTreeNode(
                    name: trimmedTitle.isEmpty ? record.sessionId : record.title,
                    path: "cmux-virtual-past-session://\(record.agent)/\(record.sessionId)",
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
        reloadCoalesceTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.reloadCoalesceTask = nil
            self.reload()
        }
    }

    private static func buildChildren(
        ofDirectory directory: String,
        depth: Int,
        maxDepth: Int,
        budget: inout Int,
        indexedTitleByPath: [String: String]
    ) -> [NotesTreeNode] {
        guard depth < maxDepth, budget > 0 else { return [] }
        let entries = NotesTreeStorage.listEntries(inDirectory: directory, limit: budget)
        var nodes: [NotesTreeNode] = []
        for entry in entries {
            guard budget > 0 else { break }
            budget -= 1
            let children = entry.kind.isDirectory
                ? buildChildren(
                    ofDirectory: entry.path,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    budget: &budget,
                    indexedTitleByPath: indexedTitleByPath
                )
                : nil
            let indexedTitle = indexedTitleByPath[(entry.path as NSString).standardizingPath]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (entry.kind == .note && indexedTitle?.isEmpty == false)
                ? indexedTitle!
                : entry.name
            nodes.append(NotesTreeNode(name: name, path: entry.path, kind: entry.kind, children: children))
        }
        return nodes
    }

    // MARK: - Session folders

    /// Add a session pointer as a real session folder in `folder` (or the
    /// workspace root). Used by drags (from the Vault, another Notes tree, or
    /// a virtual row) and by virtual-row materialization. Idempotent per
    /// agent + session id — re-adding the same session reuses its folder.
    /// Returns the folder path. Only acted-on sessions get folders; the rest
    /// stay virtual, so the tree never floods the repo's `.cmux/notes` with
    /// empty dirs.
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
    /// Returns the folder path. Idempotent per agent + session id via
    /// `addSession`.
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
        guard let root = resolvedRootPath, currentRootIsTrusted(root) else {
            clearRenderedRoot()
            return
        }
        markerRefreshTask = Task { @MainActor [weak self] in
            defer { self?.markerRefreshTask = nil }
            guard let self else { return }
            let observation = await provider?() ?? NotesTreeObservation()
            let observed = observation.sessions
            // Observations need the workspace folder + marker on disk to
            // persist into; materialize it lazily the first time this
            // workspace actually runs an agent (one small folder — not the
            // per-session flood the old auto-materialization caused).
            if !observed.isEmpty || !observation.anonymousAgents.isEmpty {
                _ = try? self.ensureRoot(folder: nil)
            }
            guard self.hasWorkspace,
                  self.resolvedRootPath == root,
                  self.currentRootIsTrusted(root)
            else {
                self.clearRenderedRootIfCurrent(root)
                return
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
            // Bound the per-tick fan-out: every cwd costs a real agent-store
            // scan and this runs on the visible-sidebar cadence. The workspace
            // cwd refreshes every tick; foreign cwds rotate through a fixed
            // budget across ticks. Each cwd uses a small row-budget-derived
            // entry cap, so a large historical agent store cannot reread tens
            // of thousands of sessions just because the Notes tab is visible.
            let otherCwds = cwds.subtracting([workspaceCwd]).sorted()
            let foreignBudget = 7
            let liveEntryLimit = self.liveSessionEntryLimit
            let scanOthers: [String]
            if otherCwds.count <= foreignBudget {
                scanOthers = otherCwds
            } else {
                let start = self.liveScanRotation
                scanOthers = (0..<foreignBudget).map { otherCwds[(start + $0) % otherCwds.count] }
                self.liveScanRotation = (start + foreignBudget) % otherCwds.count
            }
            var live: [NotesSessionDescriptor] = []
            for scanCwd in [workspaceCwd] + scanOthers {
                guard !Task.isCancelled else { return }
                let entries = await SessionIndexStore.loadLiveSessionEntries(
                    cwdFilter: scanCwd,
                    limit: liveEntryLimit
                )
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
            // bind each agent-on-a-pane-TTY to the workspace cwd's session
            // files, but only when the match is unambiguous — see
            // NotesTreeAnonymousResolution.
            let anonymous = observation.anonymousAgents + lateObservation.anonymousAgents
            let resolvedAnonymous = NotesTreeAnonymousResolution.resolve(
                anonymous: anonymous,
                liveSessions: liveSnapshot,
                workspaceCwd: workspaceCwd
            )
            let allObserved = observed + lateObserved + resolvedAnonymous
            if !allObserved.isEmpty, observed.isEmpty {
                _ = try? self.ensureRoot(folder: nil)
            }
            guard self.hasWorkspace,
                  self.resolvedRootPath == root,
                  self.currentRootIsTrusted(root)
            else {
                self.clearRenderedRootIfCurrent(root)
                return
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
            guard !Task.isCancelled, self.hasWorkspace,
                  self.resolvedRootPath == root,
                  self.currentRootIsTrusted(root)
            else {
                self.clearRenderedRootIfCurrent(root)
                return
            }
            #if DEBUG
            cmuxDebugLog(
                "notes.refresh observed=\(observed.count) late=\(lateObserved.count) "
                + "anon=\(anonymous.count) anonResolved=\(resolvedAnonymous.count) "
                + "folders=\(folders.count) live=\(liveSnapshot.count) changed=\(changed) "
                + "terminals=\(lateObservation.terminals.count) "
                + "records=\(NotesTreeStorage.readWorkspaceSessions(inRoot: root).count)"
            )
            #endif
            // The late pass re-observed the panes; prefer it (it includes any
            // terminal the cold first pass missed). applyObservedTerminals
            // reloads when the pane set changed, so the plain `changed` reload
            // below only runs when it didn't already.
            let terminals = lateObservation.terminals.isEmpty
                ? observation.terminals
                : lateObservation.terminals
            let terminalsChanged = terminals != self.observedTerminals
            let observedSessionsChanged = self.updateObservedSessionKeys(sessions: allObserved)
            self.applyObservedTerminals(terminals)
            if (changed || observedSessionsChanged), !terminalsChanged { self.reload() }
            if allObserved.isEmpty, self.emptyObservationRetries < self.maxEmptyObservationRetries {
                self.emptyObservationRetries += 1
                self.emptyObservationRetryTask?.cancel()
                self.emptyObservationRetryTask = Task { @MainActor [weak self, clock] in
                    try? await clock.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled,
                          self.hasWorkspace, self.resolvedRootPath == root else { return }
                    self.refreshSessions(force: true)
                }
            } else if !allObserved.isEmpty {
                self.emptyObservationRetries = 0
                self.emptyObservationRetryTask?.cancel()
                self.emptyObservationRetryTask = nil
            }
        }
    }

    // MARK: - Mutations

    private func currentRootIsTrusted(_ root: String) -> Bool {
        if let projectRoot,
           !NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) {
            return false
        }
        return !NotesTreeStorage.isSymlink(root)
    }

    private func clearRenderedRootIfCurrent(_ root: String) {
        guard resolvedRootPath == root else { return }
        clearRenderedRoot()
    }

    private func clearRenderedRoot() {
        rootNodes = []
        contentRevision &+= 1
    }

    @discardableResult
    private func updateObservedSessionKeys(sessions: [NotesTreeObservedSession]) -> Bool {
        let next = Set(sessions.map { Self.sessionKey(agent: $0.agent, sessionId: $0.sessionId) })
        guard next != observedSessionKeys || sessions != observedSessions else { return false }
        observedSessionKeys = next
        observedSessions = sessions
        return true
    }

    private static func sessionKey(agent: String, sessionId: String) -> String {
        "\(agent)\n\(sessionId)"
    }

    private static func terminalActiveSessions(
        records: [NotesWorkspaceSessionRecord],
        observations: [NotesTreeObservedSession]
    ) -> [String: NotesSessionMarker] {
        var recordByKey: [String: NotesWorkspaceSessionRecord] = [:]
        for record in records {
            recordByKey[Self.sessionKey(agent: record.agent, sessionId: record.sessionId)] = record
        }
        var active: [String: NotesSessionMarker] = [:]
        for observation in observations {
            let key = Self.sessionKey(agent: observation.agent, sessionId: observation.sessionId)
            let record = recordByKey[key]
            let marker = NotesSessionMarker(
                agent: record?.agent ?? observation.agent,
                sessionId: record?.sessionId ?? observation.sessionId,
                cwd: record?.cwd ?? "",
                title: record?.title ?? "",
                modified: record?.modified,
                userCreated: nil
            )
            if let panelId = observation.terminalPanelId, active[panelId] == nil {
                active[panelId] = marker
            }
            if let anchor = observation.surfaceAnchorId, active[anchor] == nil {
                active[anchor] = marker
            }
        }
        return active
    }

    /// Create a new empty note in `folder` (or the workspace root if nil).
    @discardableResult
    func newNote(inFolder folder: String? = nil) -> String? {
        guard let target = try? ensureRoot(folder: folder) else { return nil }
        let path = try? NotesTreeStorage.newNote(inFolder: target)
        if let path { reflectCreatedPath(path, kind: .note) }
        reload()
        return path
    }

    /// Create a new subfolder in `folder` (or the workspace root if nil).
    @discardableResult
    func newFolder(inFolder folder: String? = nil) -> String? {
        guard let target = try? ensureRoot(folder: folder) else { return nil }
        let path = try? NotesTreeStorage.newFolder(inFolder: target)
        if let path { reflectCreatedPath(path, kind: .folder) }
        reload()
        return path
    }

    private func reflectCreatedPath(_ path: String, kind: NotesTreeKind) {
        guard let root = resolvedRootPath else { return }
        let standardizedRoot = (root as NSString).standardizingPath
        let standardizedPath = (path as NSString).standardizingPath
        guard NotesTreeStorage.isWithin(child: standardizedPath, orEqualTo: standardizedRoot) else {
            return
        }
        let parentPath = (standardizedPath as NSString).deletingLastPathComponent
        let node = NotesTreeNode(
            name: (standardizedPath as NSString).lastPathComponent,
            path: standardizedPath,
            kind: kind,
            children: kind.isDirectory ? [] : nil
        )

        if parentPath == standardizedRoot {
            Self.upsertCreatedNode(node, into: &rootNodes)
            contentRevision &+= 1
            return
        }
        guard let parent = Self.findNode(path: parentPath, in: rootNodes),
              parent.kind.isDirectory else { return }
        var children = parent.children ?? []
        Self.upsertCreatedNode(node, into: &children)
        parent.children = children
        contentRevision &+= 1
    }

    private static func upsertCreatedNode(_ node: NotesTreeNode, into nodes: inout [NotesTreeNode]) {
        if let index = nodes.firstIndex(where: { $0.path == node.path }) {
            nodes[index] = node
        } else {
            nodes.append(node)
        }
        nodes.sort(by: nodeDisplayOrder)
    }

    private static func findNode(path: String, in nodes: [NotesTreeNode]) -> NotesTreeNode? {
        let target = (path as NSString).standardizingPath
        for node in nodes {
            if (node.path as NSString).standardizingPath == target {
                return node
            }
            if let children = node.children,
               let match = findNode(path: target, in: children) {
                return match
            }
        }
        return nil
    }

    /// Rename a note/folder in place. Confined to the project's `.cmux/notes`
    /// directory (which covers both the workspace subtree and the flat notes
    /// at its root). Carries the collapsed-state of the renamed subtree over
    /// to its new path so a rename doesn't visually re-expand everything
    /// beneath it. Returns the new path, or nil when the rename was rejected.
    @discardableResult
    func rename(path: String, toName newName: String) -> String? {
        guard isMutablePath(path) else { return nil }
        let oldPrefix = (path as NSString).standardizingPath
        guard let renamed = try? NotesTreeStorage.plannedRenameDestination(
            sourcePath: oldPrefix,
            toName: newName
        ) else {
            reload()
            return nil
        }
        let newPrefix = (renamed as NSString).standardizingPath
        do {
            if oldPrefix != newPrefix {
                try rebaseIndexedBodies(from: oldPrefix, to: newPrefix)
                do {
                    try FileManager.default.moveItem(atPath: oldPrefix, toPath: newPrefix)
                } catch {
                    try? rebaseIndexedBodies(from: newPrefix, to: oldPrefix)
                    throw error
                }
            }
        } catch {
            reload()
            return nil
        }
        if oldPrefix != newPrefix {
            collapsedPaths = Set(collapsedPaths.map { collapsed in
                if collapsed == oldPrefix { return newPrefix }
                if collapsed.hasPrefix(oldPrefix + "/") {
                    return newPrefix + collapsed.dropFirst(oldPrefix.count)
                }
                return collapsed
            })
        }
        postRelocation(from: oldPrefix, to: newPrefix)
        reload()
        return renamed
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
              let record = indexedNoteRecord(path: path) else { return nil }
        let moved = try? CmuxNoteStore.relocateBody(
            slug: record.slug, projectRoot: projectRoot, toDirectory: destinationFolder
        )
        if let moved {
            if let workspaceAnchorId {
                _ = try? CmuxNoteStore.attachBodyPath(
                    moved,
                    projectRoot: projectRoot,
                    to: .workspace(workspaceAnchorId: workspaceAnchorId)
                )
            }
            postRelocation(from: path, to: moved)
        }
        reload()
        return moved
    }

    /// File a note under a terminal virtual row. Terminal rows are not real
    /// directories, so the note becomes an indexed flat note attached to that
    /// terminal's surface anchor; if the body currently lives inside the
    /// workspace tree, move it back to the flat notes directory so it no
    /// longer appears in its old filesystem location.
    @discardableResult
    func attachNote(
        path: String,
        toTerminal terminal: NotesTreeObservedTerminal,
        target: CmuxNoteAttachmentTarget
    ) -> String? {
        guard let projectRoot,
              let notesDir = notesDirPath,
              let root = resolvedRootPath,
              isMutablePath(path) else { return nil }
        let surfaceAnchorId: String
        switch target {
        case .surface(let workspaceAnchorId, let anchorId, let surfaceKind)
            where workspaceAnchorId == self.workspaceAnchorId && surfaceKind == PanelType.terminal.rawValue:
            surfaceAnchorId = anchorId
        default:
            return nil
        }

        if let index = observedTerminals.firstIndex(where: { $0.panelId == terminal.panelId }),
           observedTerminals[index].anchorId != surfaceAnchorId {
            observedTerminals[index].anchorId = surfaceAnchorId
        }

        guard let attached = try? CmuxNoteStore.attachBodyPath(
            path,
            projectRoot: projectRoot,
            to: target
        ) else {
            reload()
            return nil
        }

        var bodyPath = CmuxNoteStore.noteBodyPath(for: attached, projectRoot: projectRoot)
        if NotesTreeStorage.isWithin(child: bodyPath, orEqualTo: root),
           let relocated = try? CmuxNoteStore.relocateBody(
                slug: attached.slug,
                projectRoot: projectRoot,
                toDirectory: notesDir
           ) {
            postRelocation(from: bodyPath, to: relocated)
            bodyPath = relocated
        }
        reload()
        return bodyPath
    }

    /// Rename an index-owned flat note by retitling its index record — the
    /// record title is what the tree displays for these notes, and their body
    /// path is pinned by `index.json`, so no file moves. Returns the
    /// (unchanged) body path on success, nil when the path has no index
    /// record. A whitespace-only title keeps the current one.
    @discardableResult
    func renameFlatNote(path: String, toTitle newTitle: String) -> String? {
        guard let projectRoot else { return nil }
        let target = (path as NSString).standardizingPath
        guard let record = indexedNoteRecord(path: path) else { return nil }
        guard let retitled = try? CmuxNoteStore.retitle(
            slug: record.slug, projectRoot: projectRoot, title: newTitle
        ) else {
            reload()
            return nil
        }
        // Open panels on this note show the record title in their tab; let
        // them adopt the new one (the body path is unchanged, so the
        // relocation notification doesn't cover renames of flat notes).
        NotificationCenter.default.post(
            name: .cmuxNoteRetitled,
            object: nil,
            userInfo: ["bodyPath": target, "title": retitled.title]
        )
        reload()
        return target
    }

    /// Delete an index-owned flat note through the tree UI: remove the index
    /// record, move the body to Trash, and restore the record if Trash fails.
    /// Trashing only the body file would leave `cmux note list` showing a note
    /// whose `read` fails.
    func deleteFlatNote(path: String) {
        guard let projectRoot,
              indexedNoteRecord(path: path) != nil else {
            reload()
            return
        }
        let target = (path as NSString).standardizingPath
        let removedRecords: [CmuxNoteRecord]
        do {
            removedRecords = try CmuxNoteStore.removeRecords(
                underAbsolutePath: target,
                projectRoot: projectRoot
            )
        } catch {
            reload()
            return
        }
        guard !removedRecords.isEmpty else {
            reload()
            return
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
        } catch {
            try? CmuxNoteStore.restoreRecords(removedRecords, projectRoot: projectRoot)
            reload()
            return
        }
        reload()
    }

    func isIndexedNote(path: String) -> Bool {
        indexedNoteRecord(path: path) != nil
    }

    private func indexedNoteRecord(path: String) -> CmuxNoteRecord? {
        guard let projectRoot,
              let records = try? CmuxNoteStore.list(projectRoot: projectRoot) else { return nil }
        let target = (path as NSString).standardizingPath
        return records.first {
            (CmuxNoteStore.noteBodyPath(for: $0, projectRoot: projectRoot) as NSString)
                .standardizingPath == target
        }
    }

    /// A path the tree may rename/delete: inside `.cmux/notes`, but never the
    /// notes directory itself nor the workspace's own root folder.
    func isMutablePath(_ path: String) -> Bool {
        if let projectRoot, !NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) {
            return false
        }
        guard let notesDir = notesDirPath,
              NotesTreeStorage.isWithin(child: path, orEqualTo: notesDir) else { return false }
        let standardized = (path as NSString).standardizingPath
        if standardized == (notesDir as NSString).standardizingPath { return false }
        if let root = resolvedRootPath, standardized == (root as NSString).standardizingPath { return false }
        if Self.containsProtectedNotesComponent(path: standardized, notesDir: notesDir) { return false }
        return true
    }

    private static func containsProtectedNotesComponent(path: String, notesDir: String) -> Bool {
        let root = (notesDir as NSString).standardizingPath
        guard path.hasPrefix(root + "/") else { return false }
        let relative = path.dropFirst(root.count + 1)
        return relative.split(separator: "/").contains { component in
            let name = String(component)
            return name.hasPrefix(".") ||
                name == "index.json" ||
                name == NotesTreeStorage.workspaceMarkerName ||
                name == NotesTreeStorage.sessionMarkerName
        }
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
        guard let folder else { return root }
        // Fail closed on a stale or foreign destination: silently retargeting
        // the mutation at the workspace root would create or move items in the
        // wrong place. Callers surface this as a nil/no-op result.
        guard NotesTreeStorage.isWithin(child: folder, orEqualTo: root) else {
            throw NotesTreeStorageError.invalidMove
        }
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
    private static func watcherDirectories(
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

    private func refreshWatchers(forDirectories dirs: Set<String>) {
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

    private func cancelPendingReload() {
        reloadGeneration &+= 1
        reloadTask?.cancel()
        reloadTask = nil
    }

    private func stopWatchers() {
        for task in watcherTasks { task.cancel() }
        watcherTasks = []
        watchers = []
        watchedDirs = []
    }

    deinit {
        for task in watcherTasks { task.cancel() }
        reloadTask?.cancel()
        reloadCoalesceTask?.cancel()
        markerRefreshTask?.cancel()
        visibilityRefreshTask?.cancel()
        emptyObservationRetryTask?.cancel()
    }
}

