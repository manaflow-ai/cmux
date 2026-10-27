import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextHibernation
import CmuxNextPages

/// Presentation, warm set and the content lifecycle of `TabContentCache`
/// (plans/cmux-next/tab-lifecycle.md).
///
/// The ledger says which pane presents a tab and whether it renders; each
/// rendering change becomes one `ContentLifecycle` event, and its effects
/// are applied here synchronously and in order. Nothing between an event
/// and its effects awaits, and the only asynchronous steps (a terminal
/// preview, a page being created or restored) come back with the token of
/// the effect that started them and are dropped when it is no longer
/// current. That is what keeps a late completion from hiding, showing or
/// reparenting the view of a newer selection.
extension TabContentCache {
    /// Drops terminal surfaces whose tabs no longer exist.
    func prune(liveTabs: Set<String>) {
        for key in terminals.keys where !liveTabs.contains(key) { release(key) }
    }

    // MARK: Presentation

    /// `presenter` shows `key` (its view is, or is about to be, in the presenter's hierarchy).
    /// Takes the surface from any previous presenter.
    func present(_ key: String, by presenter: any SurfacePresenter, presence: SurfacePresence) {
        let owner = ObjectIdentifier(presenter)
        presenters[owner] = WeakPresenter(value: presenter)
        apply(ledger.present(key, by: owner, presence: presence))
        // A shown tab that moved to a pane of another window, with no show of its own.
        if ledger.isRendering(key) { notePageScreen(key) }
    }

    /// `presenter` stopped showing `key`. Ignored when another presenter took it meanwhile (the tab moved there).
    func withdraw(_ key: String, by presenter: any SurfacePresenter) {
        apply(ledger.withdraw(key, by: ObjectIdentifier(presenter)))
    }

    /// `presenter` scrolled on screen, into the keep-alive band, or away.
    func setPresence(_ presence: SurfacePresence, presenter: any SurfacePresenter) {
        apply(ledger.setPresence(presence, owner: ObjectIdentifier(presenter)))
    }

    /// `presenter` is going away.
    func removePresenter(_ presenter: any SurfacePresenter) {
        let owner = ObjectIdentifier(presenter)
        apply(ledger.removeOwner(owner))
        presenters[owner] = nil
    }

    // MARK: Off-screen windows

    /// `window` went off screen (minimized, another Space, covered by the app's own window, the app
    /// hidden or the displays asleep: `WindowOcclusionChecker`) or came back. As Chrome's
    /// `Visibility::OCCLUDED`, the pages its panes show get a hidden clock but stay shown, and the
    /// discarder keeps each as its window's active tab (`kActiveTab`, discard_eligibility_policy.cc);
    /// the panes keep no neighbor tabs awake, so those sleep after the timeout. Hiding the shown
    /// pages themselves at once is the fork's tab visibility (API 37) or, before it, the freeze of
    /// `offScreenWindowPageFreeze` (p07-memory-097). Terminals pause their drawing (`WindowDrawPolicy`).
    func windowDidChangeOnScreen(_ window: ObjectIdentifier, offScreen: Bool) {
        guard offScreen ? offScreenWindows.insert(window).inserted : offScreenWindows.remove(window) != nil else { return }
        var panes: [ObjectIdentifier] = []
        var shown: [String] = []
        for (owner, entry) in presenters {
            guard let presenter = entry.value, presenter.presentingWindow.map({ ObjectIdentifier($0) }) == window else { continue }
            panes.append(owner)
            shown += ledger.keys(ownedBy: owner).filter { browsers[$0] != nil && ledger.isRendering($0) }
        }
        hibernation?.panesDidChangeScreen(panes, shownPages: shown, offScreen: offScreen)
    }

    /// A window reported off screen closed. It is forgotten without coming back on screen, so
    /// nothing it shows is shown again and no neighbor of its panes wakes while they are torn down.
    func offScreenWindowDidClose(_ window: ObjectIdentifier) {
        offScreenWindows.remove(window)
    }

    /// Tells hibernation whether shown page `key` is in an off-screen window (a tab switch or move
    /// there, or a show while its window is off screen).
    private func notePageScreen(_ key: String) {
        guard browsers[key] != nil, let hibernation else { return }
        hibernation.pageDidChangeScreen(key, offScreen: isInOffScreenWindow(key))
    }

    private func isInOffScreenWindow(_ key: String) -> Bool {
        guard !offScreenWindows.isEmpty, let window = presenter(of: key)?.presentingWindow else { return false }
        return offScreenWindows.contains(ObjectIdentifier(window))
    }

    /// The pane presenting `key`, if any.
    func presenter(of key: String) -> (any SurfacePresenter)? {
        ledger.owner(of: key).flatMap { presenters[$0]?.value }
    }

    func isRendering(_ key: String) -> Bool { ledger.isRendering(key) }

    /// `key`'s content phase (`debug.surfaces`, hibernation, the tab strip).
    func phase(of key: String) -> ContentLifecycle<String>.Phase { lifecycle.phase(key) }

    // MARK: Warm set (memory pressure: `WarmSetRelease`, below)

    /// `evictsAtOnce`: a smaller warm budget evicts, so the closed surfaces keep no last picture.
    func apply(_ effects: SurfaceLedger<String, ObjectIdentifier>.Effects, evictsAtOnce: Bool = false) {
        guard !effects.isEmpty else { return }
        for displaced in effects.displaced {
            presenters[displaced.owner]?.value?.surfaceWasDisplaced(displaced.key)
        }
        for (key, render) in effects.rendering.sorted(by: { !$0.value && $1.value }) {
            // Hides first, so a frame never shows two tabs of one pane.
            applyLifecycle(lifecycle.send(render ? .show(key) : .hide(key)))
        }
        for (key, away) in effects.away { terminals[key]?.session.releasesGPUWhilePaused = away } // after the hides: paused, away lets GPU memory go
        for key in effects.evicted {
            if let entry = terminals.removeValue(forKey: key) { evict(entry, key: key, atOnce: evictsAtOnce) }
            applyLifecycle(lifecycle.send(.released(key)))
        }
        for displaced in effects.displaced where presenters[displaced.owner]?.value == nil { presenters[displaced.owner] = nil } // O(changed); removePresenter drops the rest
        presentationChanges.notify(changed: Set(effects.rendering.keys).union(effects.evicted).union(effects.displaced.map(\.key)))
    }

    /// A hidden terminal leaves the warm set: its last frame stays (no copy), then it closes.
    private func evict(_ entry: TerminalEntry, key: String, atOnce: Bool) {
        lastFrames.evict(entry.session, key: key, atOnce: atOnce)
        entry.session.view.removeFromSuperview()
        entry.close()
    }

    // MARK: Lifecycle effects

    /// Content for `key` now exists: answers an outstanding `mount`.
    func contentDidMount(_ key: String) {
        guard let token = pendingMounts.removeValue(forKey: key) else { return }
        applyLifecycle(lifecycle.send(.mounted(key, token)))
    }

    func applyLifecycle(_ effects: [ContentLifecycle<String>.Effect]) {
        for effect in effects {
            switch effect {
            case .mount(let key, let token):
                trace(key, "mount \(token)")
                if hasContent(for: key) || contentOwners.contentAdopted(key) || adoptLifecyclePage(key) { // a page or conversation tab's view: live
                    applyLifecycle(lifecycle.send(.mounted(key, token)))
                } else {
                    pendingMounts[key] = token
                }
            case .reveal(let key, let token):
                trace(key, "reveal \(token)")
                reveal(key)
            case .conceal(let key, let token):
                trace(key, "conceal \(token)")
                conceal(key, token: token)
            case .release(let key, let token):
                trace(key, "hibernate \(token)")
                if !contentOwners.releaseContent(key, token: token) { hibernation?.release(key, token: token) }
            case .restore(let key, let token):
                trace(key, "restore \(token)")
                if !contentOwners.restoreContent(key, token: token) { hibernation?.restore(key, token: token) }
            }
        }
    }

    /// A page tab showing a cmux page under `pageLifecycle` is live once its view exists, so its reveal and
    /// conceal reach the page lifecycle; its memory is that lifecycle's, never the warm set's.
    private func adoptLifecyclePage(_ key: String) -> Bool {
        guard pageLifecycle?.pageOfTab(key) != nil else { return false }
        ledger.setRetained(key, false)
        return true
    }

    /// Installs the page that replaces a tab's page (`swapPage`). The tab's
    /// lifecycle does not change, so no reveal follows: a tab on screen
    /// shows the new page at once (a remote view tab's Connect starts its
    /// stream here; before, the replacement never learned it was visible).
    func installReplacement(_ page: any BrowserTab, for key: String) {
        _ = install(page, for: key)
        if shownPages.contains(key) { page.setContentVisible(true) }
    }

    private func reveal(_ key: String) {
        pageLifecycle?.tabDidShow(key) // first: a frozen page thaws in this turn, before its view shows
        if let entry = terminals[key] {
            entry.session.isRenderingSuspended = false
            entry.io.setVisible(true)
            // A new session after an eviction shows its last frame until its content draws (one that
            // parsed its content while hidden draws it now: no hold).
            lastFrames.show(key, on: entry.session)
        }
        if let entry = browsers[key] {
            entry.tab.setContentVisible(true)
            shownPages.insert(key)
        }
        if !contentOwners.contentDidShow(key) { hibernation?.tabDidShow(key) }
        notePageScreen(key)
    }

    private func conceal(_ key: String, token: ContentLifecycle<String>.Token) {
        // First, as `reveal` thaws first: the page lifecycle pictures the page while it still shows, before
        // anything below tells its engine it is hidden (a hidden page has no frame to picture), and a page
        // tab's discard cover (`contentDidHide`) then shares that capture (`PageWebView.hideFrame`).
        pageLifecycle?.tabDidHide(key)
        if let entry = terminals[key] {
            // No picture on a switch: hover and drag render one on demand (`previewImage`), or `evict` keeps one.
            entry.session.isRenderingSuspended = true
            entry.io.setVisible(false)
        }
        if let entry = browsers[key] {
            // Only a page that was on screen (one created or restored hidden has nothing worth a
            // thumbnail), and only when it navigated or loaded since its last picture: the engine
            // cannot picture a hidden page, so this is its last chance; a plain switch takes none.
            if shownPages.remove(key) != nil, !pagePictureIsCurrent(entry, key: key) {
                capturePagePreview(entry, key: key, token: token)
            }
            entry.tab.setContentVisible(false)
        }
        if !contentOwners.contentDidHide(key, token: token) { hibernation?.tabDidHide(key) }
    }

    func trace(_ key: String, _ event: String) {
        InputJournal.shared.append(window: nil, .content(tab: key, event: event))
    }
}

extension TabContentCache: WarmSetHost {
    var warmCapacity: Int { ledger.capacity }
    var warmHiddenCount: Int { ledger.hiddenCount }
    var leastRecentlyHiddenAge: Duration? { ledger.leastRecentlyHiddenAge }
    func warmBudgetDidChange(to capacity: Int) {
        warmBudget = WarmSetBudget(terminalCapacity: capacity)
        // Bounds the frames kept from now on; it drops no stored frame (the memory coordinator's
        // critical release slices do, `memoryTerminalLastFrames`).
        lastFrames.setCapacity(capacity)
    }
    func setWarmCapacity(_ capacity: Int) -> Int {
        let effects = ledger.setCapacity(capacity)
        apply(effects, evictsAtOnce: true) // only a smaller capacity evicts
        return effects.evicted.count
    }
}
