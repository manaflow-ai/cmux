import AppKit
import CmuxNextBrowser
import CmuxNextDaemon

// Incognito windows (user decision 2026-09-30): a whole window whose
// browser pages use one off-the-record browser profile (Chromium in-memory
// context, WebKit non-persistent store). Terminals in it are normal
// terminals. Nothing moves between an incognito window and a normal one
// (`WindowRegistry`), closing one closes its workspaces, the last one
// closing deletes the browser data, and none is restored after relaunch.
extension WindowManager {
    /// Opens a new incognito window whose workspace holds one browser tab on
    /// `url` (a blank page when nil). Returns the window id at once; the
    /// window opens when the daemon reports the workspace.
    @discardableResult
    func newIncognitoWindow(url: URL? = nil) -> String {
        let windowID = UUID().uuidString.lowercased()
        registry.apply { registry in
            registry.markIncognito(windowID)
            return WindowRegistry.Changes()
        }
        // The session begins now, so the window's first page is incognito.
        _ = incognitoProfile()
        let daemon = services.daemon
        let browserTabs = services.cache.browserTabs!
        let choice: BrowserEngineChoice = if case .open(let choice) = browserTabs.resolve(requested: nil) {
            choice
        } else {
            BrowserEngineChoice(engine: .webkit)
        }
        let address = url?.absoluteString ?? "about:blank"
        if EphemeralWorkspaces.localDaemonServes(self) {
            EphemeralWorkspaces.newIncognitoWorkspace(self, window: windowID, address: address, choice: choice)
            return windowID
        }
        // Claimed before anything else runs: the pending claim keeps the
        // session alive until the window opens.
        let key = WorkspaceKey.generate()
        claimNew(workspaceID: key.rawValue, window: windowID)
        Task { [services] in
            guard let connection = daemon.connection else {
                pendingClaims[key.rawValue] = nil
                return endIncognitoSessionIfUnused()
            }
            do {
                _ = try await WorkspaceCreation.create(key, name: nil, on: connection, repair: services.emptyWorkspaces) { created in
                    let terminal = try await connection.createTerminal(in: created, cwd: daemon.defaultCwd ?? NSHomeDirectory())
                    if let pane = terminal.pane {
                        _ = try await browserTabs.open(choice, in: pane, url: address, incognito: true)
                        if let surface = terminal.surface { try await connection.closeTab(surface) }
                    }
                    return created.rawValue
                }
            } catch {
                daemon.logger.error("new incognito window failed: \(String(describing: error), privacy: .public)")
                pendingClaims[key.rawValue] = nil
                endIncognitoSessionIfUnused()
            }
        }
        return windowID
    }

    /// The incognito session's browser profile, begun on first use.
    func incognitoProfile() -> BrowserProfileID {
        if let profile = incognitoSession { return profile }
        let profile = OffTheRecordProfiles.shared.begin()
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
        return pendingClaims[workspaceID].map(value.isIncognito) ?? false
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
        for (workspace, window) in pendingClaims where value.isIncognito(window) { ids.insert(workspace) }
        // The daemon closes ephemeral workspaces itself; the ledger keeps
        // only incognito workspaces it does not know as such.
        incognitoLedger.record(ids.filter { !EphemeralWorkspaces.isEphemeral($0, self) })
    }

    func endIncognitoSessionIfUnused() {
        guard let profile = incognitoSession else { return }
        let value = registry.value
        let open = value.windows.contains { value.isIncognito($0.id) }
        let pending = pendingClaims.values.contains(where: value.isIncognito) || !pendingEphemeralWindows.isEmpty
        guard !open, !pending else { return }
        incognitoSession = nil
        incognitoHistoryReset?()
        OffTheRecordProfiles.shared.end(profile)
    }

    /// Quit: incognito windows are never restored, so their workspaces
    /// close now (on the daemons), before the window state is saved.
    func closeIncognitoWindowsForTermination() async {
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
    /// a new window of that kind (incognito even before the daemon reports
    /// the workspace); an open one places it by `workspaces.newPlacement`.
    func placeMoved(_ key: String, from origin: MoveOrigin, preferred: WindowState?, newWindow: Bool, select shows: Bool = true) {
        if newWindow {
            openWindow(workspaces: [key], incognito: origin.incognito, behind: !shows)
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
        registry.value.owner(of: workspaceID) ?? pendingClaims[workspaceID]
    }

    /// True when moving content of workspace `source` into workspace
    /// `target` would cross between an incognito window and a normal one.
    func crossesIncognito(from source: String?, to target: String?) -> Bool {
        guard let source, let target else { return false }
        return isIncognito(workspace: source) != isIncognito(workspace: target)
    }

    /// True when moving content of workspace `source` into (a new workspace
    /// of) window `windowID` would cross kinds.
    func crossesIncognito(from source: String?, toWindow windowID: String) -> Bool {
        guard let source else { return false }
        return isIncognito(workspace: source) != isIncognito(window: windowID)
    }
}
