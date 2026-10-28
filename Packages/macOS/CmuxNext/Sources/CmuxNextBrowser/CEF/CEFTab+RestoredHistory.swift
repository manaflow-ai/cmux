import Foundation

/// Session history across relaunch (`CEFRestoredSession`).
extension CEFTab: BrowserSessionRestoring {
    public func restoreSession(_ entries: [BrowserSavedEntry], current: Int) {
        restored.restore(entries, current: current)
    }

    public func currentScrollY() async -> Double? {
        guard case .number(let y)? = try? await evaluate("window.scrollY", world: .isolated, gesture: .cmux) else { return nil }
        return y
    }

    public func savedSession(measuringScroll: Bool) async -> BrowserSavedSession? {
        await restored.savedSession(measuringScroll: measuringScroll)
    }
}

/// Session history across a Chromium Host restart (task 083, ``CEFRuntime/restorePagesOnNextHost(_:reading:)``).
extension CEFTab {
    /// Where the page comes back after its host crashed: its last committed entry, where its saved navigation ends
    /// (a load the host was making went with it, as a crashed tab's pending entry does in Chrome), else the address
    /// it was loading.
    var hostRestoreURL: URL? { committedURL ?? state.url }

    /// The page waits for its saved navigation and the next host: no browser is made for it until then.
    var awaitsHostRestore: Bool { runtime.hostStart?.pageRestores.blocksCreation(of: self) == true }

    /// A host restore will bring the page back (``CEFHostPageRestores/Phase``).
    var hasHostRestore: Bool { runtime.hostStart?.pageRestores.phase(of: self) != nil }

    /// The host ended with this page and the next one starts now (restore `generation`). True when the page comes
    /// back on it: it waits with its crash page and makes no browser until then. A page showing a form's result (a
    /// POST) does not come back on its own, shown or hidden: the form is never sent again without the person, so it
    /// keeps its crash page until they reload it. A spare's placeholder has nothing to bring back.
    func beginHostRestore(in restores: CEFHostPageRestores, generation: UInt64) -> Bool {
        guard !isClosed, browserID == nil, host.placeholder !== self, hostRestoreURL != nil else { return false }
        guard !restored.showsFormSubmission else { return false }
        restores.set(.reading(generation), for: self)
        return true
    }

    /// The next host is attached: the page restores `saved`, Chromium's own navigation state with its back/forward
    /// list, or loads its address when there is none or Chromium refuses it (``attach(browser:)``). A shown tab gets
    /// its browser now; a hidden one when it shows (``hostRestoreShown()``), as Chrome loads a restored background tab
    /// when it is activated.
    func restoreOnRestartedHost(_ saved: String?, in restores: CEFHostPageRestores) {
        restores.set(nil, for: self)
        guard !isClosed, browserID == nil, !isCreationPending, let url = hostRestoreURL else { return }
        (pendingRestore, pendingURL) = (saved, url)
        guard host.visibleTab === self else { return restores.set(.waitsForShow, for: self) }
        startHostRestore()
        host.recreateShown(self)
    }

    /// Shown after its host restarted (`contentDidAppear`, after `present` asked for its browser): its restore starts.
    func hostRestoreShown() {
        guard let restores = runtime.hostStart?.pageRestores, restores.phase(of: self) == .waitsForShow else { return }
        restores.set(nil, for: self)
        if browserID == nil { startHostRestore() }
    }

    /// The page was sent somewhere else before its restore loaded it (``load(_:)``, from the person, a script, the CLI or
    /// MCP): the restore ends and the new address loads, as a navigation of a restored background tab replaces its
    /// pending restore in Chrome. A page still waiting for the next host gets its browser there, now when shown.
    func hostRestoreNavigated() {
        guard let restores = runtime.hostStart?.pageRestores, let phase = restores.phase(of: self) else { return }
        restores.set(nil, for: self)
        pendingRestore = nil
        if case .reading = phase { runtime.createAfterHostRestart(self) }
    }

    /// The next host did not start: the page keeps its crash page until the person reloads it, as without a restore.
    func hostRestoreFailed(in restores: CEFHostPageRestores) {
        restores.set(nil, for: self)
    }

    /// The crash page goes and the restored page starts, as a load before its browser exists does (``load(_:)``),
    /// with no gesture of the person's.
    private func startHostRestore() {
        isDiscardedInPlace = false
        let id = makeNavigationID()
        navigation = id
        machine.apply(.started(id, url: pendingURL))
    }
}
