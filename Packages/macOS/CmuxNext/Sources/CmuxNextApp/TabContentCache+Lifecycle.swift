import AppKit
import CmuxNextBridge
import CmuxNextBrowser

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

    /// `presenter` shows `key` (its view is, or is about to be, in the
    /// presenter's hierarchy). Takes the surface from any previous presenter.
    func present(_ key: String, by presenter: any SurfacePresenter, presence: SurfacePresence) {
        let owner = ObjectIdentifier(presenter)
        presenters[owner] = WeakPresenter(value: presenter)
        apply(ledger.present(key, by: owner, presence: presence))
    }

    /// `presenter` stopped showing `key`. Ignored when another presenter
    /// took it meanwhile (the tab moved there).
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

    /// The pane presenting `key`, if any.
    func presenter(of key: String) -> (any SurfacePresenter)? {
        ledger.owner(of: key).flatMap { presenters[$0]?.value }
    }

    func isRendering(_ key: String) -> Bool { ledger.isRendering(key) }

    /// `key`'s content phase (`debug.surfaces`, hibernation, the tab strip).
    func phase(of key: String) -> ContentLifecycle<String>.Phase { lifecycle.phase(key) }

    // MARK: Warm set

    /// Applies a new warm set budget (memory pressure changed).
    func setWarmBudget(_ budget: WarmSetBudget) {
        guard budget != warmBudget else { return }
        evictsAtOnce = budget.terminalCapacity < warmBudget.terminalCapacity
        defer { evictsAtOnce = false }
        warmBudget = budget
        apply(ledger.setCapacity(budget.terminalCapacity))
    }

    func apply(_ effects: SurfaceLedger<String, ObjectIdentifier>.Effects) {
        guard !effects.isEmpty else { return }
        for displaced in effects.displaced {
            presenters[displaced.owner]?.value?.surfaceWasDisplaced(displaced.key)
        }
        for (key, render) in effects.rendering.sorted(by: { !$0.value && $1.value }) {
            // Hides first, so a frame never shows two tabs of one pane.
            applyLifecycle(lifecycle.send(render ? .show(key) : .hide(key)))
        }
        for key in effects.evicted {
            if let entry = terminals.removeValue(forKey: key) { evict(entry, key: key) }
            applyLifecycle(lifecycle.send(.released(key)))
        }
        for displaced in effects.displaced where presenters[displaced.owner]?.value == nil { presenters[displaced.owner] = nil } // O(changed); removePresenter drops the rest
        presentationChanges.notify(changed: Set(effects.rendering.keys).union(effects.evicted).union(effects.displaced.map(\.key)))
    }

    /// Whether tab `key` holds memory here: a terminal surface or a live page (not a hibernated one).
    func holdsMemory(_ key: String) -> Bool {
        terminals[key] != nil || browsers[key].map { !($0.tab is HibernatedBrowserTab) } == true
    }

    /// The tabs of a hibernated workspace (plans/cmux-next/workspace-hibernation-DESIGN.md), after its
    /// panes left: terminal surfaces go now, pages are discarded after their own checks, chat pages
    /// go keeping their session.
    func hibernateTabs(_ keys: [String]) {
        for key in keys {
            evictHiddenTerminal(key)
            if browsers[key] != nil { hibernation?.hibernateForWorkspace(key) }
            hibernation?.agentPages?.releaseForWorkspace(key)
        }
    }

    /// Destroys hidden terminal `key`'s surface now (its workspace hibernated); its last frame stays
    /// and it re-attaches from the terminal host's replay when shown. A presented one stays.
    func evictHiddenTerminal(_ key: String) {
        guard terminals[key] != nil else { return }
        apply(ledger.evictHidden(key))
    }

    /// A hidden terminal leaves the warm set: its last frame stays (no copy), then it closes.
    private func evict(_ entry: TerminalEntry, key: String) {
        lastFrames.evict(entry.session, key: key, capacity: warmBudget.terminalCapacity, atOnce: evictsAtOnce)
        entry.session.view.removeFromSuperview()
        entry.close()
    }

    // MARK: Lifecycle effects

    /// Content for `key` now exists: answers an outstanding `mount`.
    func contentDidMount(_ key: String) {
        // Created with no pane showing it (a tab opened in the background): live and hidden, so
        // hibernation may release it and its first show restores it.
        guard let token = pendingMounts.removeValue(forKey: key) else { return applyLifecycle(lifecycle.send(.adopted(key))) }
        applyLifecycle(lifecycle.send(.mounted(key, token)))
    }

    func applyLifecycle(_ effects: [ContentLifecycle<String>.Effect]) {
        for effect in effects {
            switch effect {
            case .mount(let key, let token):
                trace(key, "mount \(token)")
                if hasContent(for: key) {
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
                hibernation?.release(key, token: token)
            case .restore(let key, let token):
                trace(key, "restore \(token)")
                hibernation?.restore(key, token: token)
            }
        }
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
        hibernation?.tabDidShow(key)
    }

    private func conceal(_ key: String, token: ContentLifecycle<String>.Token) {
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
        hibernation?.tabDidHide(key)
    }

    func trace(_ key: String, _ event: String) {
        InputJournal.shared.append(window: nil, .content(tab: key, event: event))
    }
}
