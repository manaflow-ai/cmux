import Foundation

extension NotesTreeStore {
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
}
