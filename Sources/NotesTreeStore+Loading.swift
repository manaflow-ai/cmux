import Foundation

extension NotesTreeStore {
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

    static func nodeDisplayOrder(_ lhs: NotesTreeNode, _ rhs: NotesTreeNode) -> Bool {
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
}
