import AppKit
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextLayout

// Incognito windows (user decision 2026-09-30): a whole window whose
// browser pages use one off-the-record browser profile (Chromium in-memory
// context, WebKit non-persistent store). Terminals in it are normal
// terminals. Closing one closes its workspaces, and none is restored after relaunch. Private tabs may sit
// in any window (Leo, 2026-11-18, `PrivateTabSession`): one uses the session's profile in a normal window,
// and only workspaces, screens, tab groups and normal tabs never go into an incognito window. The session's
// data goes once no incognito window and no private tab is left.
extension WindowManager {
    /// Opens a new incognito window whose workspace holds one browser tab on
    /// `url` (a blank page when nil). Returns the window id at once; the
    /// window opens when the daemon reports the workspace.
    /// `space`: an incognito space (spaces-overhaul-DESIGN.md rule 2): the window shows it, its workspace is
    /// pinned to it, and the space is deleted once the window is gone (`endIncognitoSpacesIfUnused`).
    @discardableResult
    func newIncognitoWindow(url: URL? = nil, space: ProfileID? = nil) -> String {
        let windowID = UUID().uuidString.lowercased()
        registry.apply { registry in
            registry.markIncognito(windowID)
            return WindowRegistry.Changes()
        }
        if let space {
            incognitoSpaces[windowID] = space
            state(for: windowID).enterProfile(space)
            recordIncognitoWorkspaces() // a crash from here on still deletes the space at the next launch
        }
        // The session begins now, so the window's first page is incognito.
        _ = incognitoProfile()
        let daemon = services.daemon
        let browserTabs = services.cache.browserTabs
        let choice: BrowserEngineChoice = if case .open(let choice) = browserTabs.resolve(requested: nil, url: url) {
            choice
        } else {
            BrowserEngineChoice(engine: .webkit)
        }
        let address = url?.absoluteString ?? "about:blank"
        if EphemeralWorkspaces.localDaemonServes(self) {
            EphemeralWorkspaces.newIncognitoWorkspace(self, window: windowID, address: address, choice: choice, space: space)
            return windowID
        }
        // Claimed before anything else runs: the pending claim keeps the session alive until the window opens.
        let key = WorkspaceKey.generate()
        claimNew(workspaceID: key.rawValue, window: windowID)
        recordIncognitoWorkspaces() // the ledger has it before the daemon creates it
        Task { [services] in
            guard let connection = daemon.connection else {
                claims.pending[key.rawValue] = nil
                return endIncognitoSessionIfUnused()
            }
            do {
                _ = try await WorkspaceCreation.create(key, name: nil, on: connection, repair: services.emptyWorkspaces, terminalFirst: false) { created in
                    if let space { try await pinToIncognitoSpace(key, space, on: daemon) }
                    let terminal = try await WorkspaceCreation.firstTerminal(in: created, cwd: NewTerminalStart.defaultFolder(on: daemon) ?? NSHomeDirectory(), on: connection)
                    if let pane = terminal.pane {
                        _ = try await browserTabs.open(choice, in: pane, on: daemon, url: address, incognito: true)
                        if let surface = terminal.surface { try await connection.closeTab(surface) }
                    }
                    return created.rawValue
                }
            } catch {
                daemon.logger.error("new incognito window failed: \(String(describing: error), privacy: .public)")
                claims.pending[key.rawValue] = nil
                endIncognitoSessionIfUnused()
            }
        }
        return windowID
    }

    /// The incognito session's browser profile, begun on first use.
    func incognitoProfile() -> BrowserProfileID {
        if let profile = incognitoSession { return profile }
        let profile = services.browserStores.offTheRecord.begin()
        incognitoSession = profile
        return profile
    }

    /// True when `workspaceID` belongs to an incognito window: listed by
    /// one, claimed for one that is about to open, or discarded with a
    /// closed one (its pages must still never use a normal store).
    func isIncognito(workspace workspaceID: String) -> Bool {
        let value = registry.value
        if value.discarding.contains(workspaceID) || EphemeralWorkspaces.isEphemeral(workspaceID, self) { return true }
        if let owner = value.owner(of: workspaceID) { return value.isIncognito(owner) }
        return claims.pending[workspaceID].map(value.isIncognito) ?? false
    }

    /// `isIncognito(workspace:)` from this workspace's own facts (no workspace list or whole registry read, F6).
    func isIncognito(workspace w: WorkspaceModel) -> Bool {
        w.ephemeral || (registry.incognitoByWorkspace[w.id] ?? claims.pending[w.id].map(registry.value.isIncognito) ?? false)
    }

    /// True when window `windowID` is incognito.
    func isIncognito(window windowID: String) -> Bool {
        registry.value.isIncognito(windowID)
    }

    /// The browser profile a page of `workspaceID` uses: the incognito
    /// session's for an incognito window, else nil (the caller's default).
    func browserProfile(forWorkspace workspaceID: String?) -> BrowserProfileID? {
        guard let workspaceID, isIncognito(workspace: workspaceID) else { return nil }
        return incognitoProfile()
    }

    /// Closes the workspaces of closed incognito windows on their daemons
    /// (terminals end with them), then ends the incognito session when no
    /// incognito window is left.
    func discard(_ workspaceIDs: [String]) {
        for id in workspaceIDs {
            guard let (workspace, daemon) = services.machines.workspace(id: id), let key = workspace.key else { continue }
            let terminals = WorkspaceClose.closing(workspace, on: daemon)
            daemon.send("close-workspace") { try await WorkspaceClose.close(key, terminals: terminals, on: $0) }
        }
        endIncognitoSessionIfUnused()
    }

    /// Ends the incognito session (every engine drops its data) once no
    /// incognito window is registered or about to open.
    /// Writes the incognito ledger (workspace ids only).
    func recordIncognitoWorkspaces() {
        let value = registry.value
        var ids = value.discarding
        for window in value.windows where value.isIncognito(window.id) { ids.formUnion(window.workspaceIDs) }
        for (workspace, window) in claims.pending where value.isIncognito(window) { ids.insert(workspace) }
        // The daemon closes ephemeral workspaces itself; the ledger keeps only incognito workspaces it does not know as such.
        incognitoLedger.record(ids.filter { !EphemeralWorkspaces.isEphemeral($0, self) }, spaces: Set(incognitoSpaces.values.map(\.rawValue)))
    }

    /// Pins the incognito window's workspace `key` on `daemon` to its incognito space, so the window, which shows
    /// that space, lists it.
    func pinToIncognitoSpace(_ key: WorkspaceKey, _ space: ProfileID, on daemon: DaemonService) async throws {
        guard let session = daemon.store.registryID, let home = services.machines.local.connection else { return }
        try await home.pinWorkspace(session: session, key: key, to: space)
    }

    /// Deletes each incognito space whose window is gone (closed, or never opened): its workspaces close with
    /// the space, as Delete Space closes the workspaces only that space shows. Nothing of it is kept.
    func endIncognitoSpacesIfUnused() {
        let value = registry.value
        let open = Set(value.windows.filter { $0.isOpen }.map(\.id)).union(claims.pending.values).union(pendingEphemeralWindows)
        for (window, space) in incognitoSpaces where !open.contains(window) {
            incognitoSpaces[window] = nil
            services.machines.local.send("delete-profile") { _ = try await $0.deleteProfile(space, moveTo: nil) }
        }
    }

    func endIncognitoSessionIfUnused() {
        endIncognitoSpacesIfUnused()
        guard let profile = incognitoSession else { return }
        let value = registry.value
        let open = value.windows.contains { value.isIncognito($0.id) }
        let pending = claims.pending.values.contains(where: value.isIncognito) || !pendingEphemeralWindows.isEmpty
        guard !open, !pending else { return }
        // Private tabs in normal windows keep the session (Leo, 2026-11-18); the watch ends it after the last one.
        if hasPrivateTabs() { return watchPrivateTabs() }
        privateTabsWatch?.cancel()
        privateTabsWatch = nil
        incognitoSession = nil
        incognitoHistoryReset?()
        services.browserStores.offTheRecord.end(profile)
    }

    func hasPrivateTabs() -> Bool { services.cache.browserTabs.privateTabs.isOpening || !privateTabs().isEmpty }

    /// The private tabs of normal windows (an incognito window's close with it), with their daemons.
    func privateTabs() -> [(TabModel, DaemonService)] {
        PrivateTabSession.tabs(of: services.machines.daemons, store: \.store, skips: isIncognito(workspace:), isPrivate: services.cache.browserTabs.isPrivate)
    }

    /// Ends the session after the last private tab (`PrivateTabSession.watch`); the session's own end cancels it.
    func watchPrivateTabs() {
        guard privateTabsWatch == nil, incognitoSession != nil else { return }
        privateTabsWatch = PrivateTabSession.watch(services.machines.daemons.map(\.store)) { [weak self] in
            guard let self, incognitoSession != nil else { self?.privateTabsWatch = nil; return false }
            endIncognitoSessionIfUnused()
            return true
        }
    }

    /// New Private Tab: a private tab in the active window's focused pane (`PrivateTabSession.route`).
    func newPrivateTab() {
        let pane = active?.focusedPane, browserTabs = services.cache.browserTabs
        let served = pane.map { $0.daemon.supports(DaemonCapability.privateTabs.rawValue) && browserTabs.isAvailable(in: $0.pane) } ?? false
        switch PrivateTabSession.route(pane: pane != nil, incognitoWindow: active.map { isIncognito(window: $0.state.id) } ?? false, served: served) {
        case .incognitoWindow: newIncognitoWindow()
        case .windowTab: _ = pane?.newBrowserTab()
        case .privateTab:
            let resolved = browserTabs.resolve(requested: nil)
            if case .refuse(let reason) = resolved { return services.registry.refuse(BrowserTabService.message(reason)) }
            guard let pane, case .open(let choice) = resolved else { return }
            _ = incognitoProfile() // the session begins now, so the tab's first page is incognito
            let address = services.newTabAddress(for: choice), intent = pane.workspace?.beginFocusIntent()
            services.registry.track(Task { [services] in
                defer { services.windows.watchPrivateTabs() }
                do {
                    let surface = try await browserTabs.open(choice, in: pane.pane, url: address, incognito: true)
                    pane.selectWhenReported(surface: surface)
                    pane.workspace?.expectFocus(on: surface, target: .addressBar, generation: intent)
                    return nil
                } catch {
                    pane.daemon.logger.error("new private tab failed: \(String(describing: error), privacy: .public)")
                    return "new private tab: \(error)"
                }
            })
        }
    }

    /// Quit: incognito windows are never restored, so their workspaces
    /// close now (on the daemons), before the window state is saved. Private
    /// tabs of normal windows close too (the daemon also closes any one an
    /// earlier run left, at its start).
    func closeIncognitoWindowsForTermination() async {
        for (tab, daemon) in privateTabs() {
            guard let connection = daemon.connection else { continue }
            try? await connection.closeTab(tab.surface)
        }
        // Incognito spaces go with their windows: none is restored.
        if let home = services.machines.local.connection {
            for space in Set(incognitoSpaces.values) { _ = try? await home.deleteProfile(space, moveTo: nil) }
        }
        incognitoSpaces = [:]
        let value = registry.value
        let ids = value.windows.filter { value.isIncognito($0.id) }.flatMap(\.workspaceIDs)
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let (workspace, daemon) = services.machines.workspace(id: id), let key = workspace.key,
                  let connection = daemon.connection else { continue }
            let terminals = WorkspaceClose.closing(workspace, on: daemon)
            try? await WorkspaceClose.close(key, terminals: terminals, on: connection)
        }
    }

    /// Records which incognito window each of its tabs is in, so a tab
    /// moved into a new workspace returns to that window (reconcile).
    func rememberIncognitoTabs() {
        let value = registry.value
        var homes: [String: String] = [:]
        for window in value.windows where value.isIncognito(window.id) {
            for id in window.workspaceIDs {
                for tab in services.workspace(id: id)?.screens.flatMap(\.panes).flatMap(\.tabs) ?? [] { homes[tab.id] = window.id }
            }
        }
        incognitoTabHomes = homes
    }

    /// Where content moved out of a workspace came from: its window and
    /// kind, captured before the move (the source may close with it).
    struct MoveOrigin {
        var window: String?
        var incognito: Bool
    }

    func moveOrigin(of workspaceID: String?) -> MoveOrigin {
        guard let workspaceID else { return MoveOrigin(window: nil, incognito: false) }
        return MoveOrigin(window: windowID(ofWorkspace: workspaceID), incognito: isIncognito(workspace: workspaceID))
    }

    /// Shows workspace `key`, just made from content moved out of `origin`,
    /// in a window of the origin's kind: `preferred` (usually the active
    /// window) when it matches, else the origin's window. `newWindow` opens
    /// a new window of that kind beside the origin's (`openMovedWindow`;
    /// incognito even before the daemon reports the workspace); an open one
    /// places it by `workspaces.newPlacement`.
    func placeMoved(_ key: String, from origin: MoveOrigin, preferred: WindowState?, newWindow: Bool, select shows: Bool = true) {
        if newWindow {
            openMovedWindow([key], from: origin, select: shows)
            return
        }
        let target = preferred.flatMap { isIncognito(window: $0.id) == origin.incognito ? $0 : nil }
            ?? origin.window.flatMap { registry.value.window($0)?.isOpen == true ? states[$0] : nil }
        guard let target else { return }
        let rule = NewWorkspacePlacements.rule(for: target.id, in: self)
        claim(workspaceID: key, in: target, select: shows)
        NewWorkspacePlacements.expect(key, in: target.id, byDefault: rule, windows: self)
    }

    /// The window a workspace is shown in, for move checks.
    func windowID(ofWorkspace workspaceID: String) -> String? {
        registry.value.owner(of: workspaceID) ?? claims.pending[workspaceID]
    }

    /// True when moving content of workspace `source` into workspace
    /// `target` would cross between an incognito window and a normal one.
    func crossesIncognito(from source: String?, to target: String?) -> Bool {
        guard let source, let target else { return false }
        return isIncognito(workspace: source) != isIncognito(workspace: target)
    }
}
