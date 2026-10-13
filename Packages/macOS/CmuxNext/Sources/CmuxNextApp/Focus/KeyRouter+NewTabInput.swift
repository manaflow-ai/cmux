import AppKit

/// Owns the short interval between Cmd-T (or Cmd-N's new workspace) and the New Tab field's
/// readiness acknowledgement: every key typed from the shortcut on waits here, in order, and goes to
/// the field once it reported ready (cx-kql5h: after Cmd-N the first 2-3 keys went to the old
/// workspace, because nothing held them while the workspace and its page were made).
///
/// The hold is bounded (nightly 2026-10-11, "cannot type at all"): while a window's buffer lives,
/// every printable key of that window waits here and a second Cmd-T opens nothing, so a buffer
/// whose acknowledgement never comes would take the whole window's typing. A buffer therefore
/// ends, giving its keys back in order to whatever has focus, when
/// - its pane no longer shows a New Tab page (the page was left or became a chat) or left the
///   window,
/// - another opening begins, or
/// - `holdLimit` passed since Cmd-T (one deadline per opening, also checked on each key, each
///   opening and each focus settle).
@MainActor
final class NewTabInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: Entry] = [:]
    /// The longest a key may wait for the New Tab field. Its readiness normally comes within one
    /// page render; past this the field (or whatever has focus) takes the keys directly.
    var holdLimit: Duration = .seconds(2)
    /// The same for a page that does not exist yet (Cmd-N): the daemon makes the workspace and its
    /// first tab first, so the field comes later than in a pane that already shows.
    var incomingHoldLimit: Duration = .seconds(4)
    /// Injected for tests; the hold limit is the only time this coordinator reads.
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// Runs `fire` once `limit` from now (a task by default; injected for tests).
    var scheduleDeadline: (_ limit: Duration, _ fire: @escaping @MainActor () -> Void) -> Task<Void, Never> = { limit, fire in
        Task { @MainActor in
            // wakeup-allow: one-shot bound on a New Tab key hold; cancelled when the hold ends first
            do { try await Task.sleep(for: limit) } catch { return }
            fire()
        }
    }

    private final class Entry {
        let buffer: NewTabInputBuffer
        let limit: Duration
        /// The tab the pane showed before Cmd-T: it counts as the opening only until the page shows.
        let opened: String?
        weak var pane: PaneController?
        weak var window: NSWindow?
        /// The open put the page's tab on screen (`didShow`).
        var shown = false
        var deadline: Task<Void, Never>?
        /// A page that does not exist yet (Cmd-N's new workspace, `beginIncoming`): its tab key
        /// comes with its readiness; until then the hold owns its window's keys.
        let incoming: IncomingPage?

        init(buffer: NewTabInputBuffer, limit: Duration, opened: String?, pane: PaneController?, window: NSWindow,
             incoming: IncomingPage? = nil) {
            self.buffer = buffer
            self.limit = limit
            self.opened = opened
            self.pane = pane
            self.window = window
            self.incoming = incoming
        }

        /// Whether the opening still owns the window's keys: its pane, in its window, shows its New
        /// Tab page (or, until the page shows, the tab it showed before). An incoming page's hold
        /// owns them until its readiness, its creation's end or its limit.
        var owns: Bool {
            guard let window else { return false }
            if incoming != nil { return true }
            guard let pane, pane.view.window === window else { return false }
            guard let key = pane.currentTabKey else { return !shown }
            if pane.services.agentTabs.isNewTabPage(key) { return true }
            return !shown && key == opened
        }
    }

    /// The page an incoming hold waits for: its token is handed to the first New Tab page made
    /// (`claimIncomingToken`), and its tab key arrives with the page's readiness.
    final class IncomingPage {
        var key: String?
        var claimed = false
    }

    init(router: KeyRouter) { self.router = router }

    func begin(for pane: PaneController) -> String? {
        guard let router, let window = pane.view.window else { return nil }
        // One opening at a time per window: an earlier one ends here and its keys go on first.
        release(in: window)
        let buffer = NewTabInputBuffer(began: now(), focusField: { [weak pane, weak window] in
            guard let pane, let window, let key = pane.currentTabKey,
                  pane.services.agentTabs.isNewTabPage(key),
                  let view = pane.services.agentTabs.existingView(key), view.window === window else { return false }
            return window.makeFirstResponder(view.webView)
        }, deliver: deliver(in: window))
        let entry = Entry(buffer: buffer, limit: holdLimit, opened: pane.currentTabKey, pane: pane, window: window)
        install(entry, in: window)
        return buffer.token
    }

    /// Cmd-N (a person's new workspace on the New Tab page, shown in `window`): from this moment
    /// every key of `window` waits for the new page's field. The first New Tab page made takes the
    /// token (`claimIncomingToken`); its readiness names its tab and sends the keys there. The
    /// creation ends the hold when it fails or makes no page (`endIncoming`).
    func beginIncoming(in window: NSWindow?) -> String? {
        guard let router, let window else { return nil }
        release(in: window)
        let target = IncomingPage()
        let services = router.services
        let buffer = NewTabInputBuffer(began: now(), focusField: { [weak services, weak window] in
            // The page shows in this window (its workspace joined it; FirstTabHold) before it takes keys.
            guard let services, let window, let key = target.key, services.agentTabs.isNewTabPage(key),
                  let view = services.agentTabs.existingView(key), view.window === window,
                  !view.isHiddenOrHasHiddenAncestor else { return false }
            return window.makeFirstResponder(view.webView)
        }, deliver: deliver(in: window))
        install(Entry(buffer: buffer, limit: incomingHoldLimit, opened: nil, pane: nil, window: window, incoming: target), in: window)
        return buffer.token
    }

    /// The token of the incoming hold that waits for its page, for the New Tab page being made (a
    /// page made twice, by the tree listing and by the create reply, gets the same token); nil
    /// when no Cmd-N waits for a page.
    func claimIncomingToken() -> String? {
        guard let entry = buffers.values.first(where: { $0.incoming != nil && $0.incoming?.key == nil }),
              let incoming = entry.incoming else { return nil }
        incoming.claimed = true
        return entry.buffer.token
    }

    /// The creation behind `token` ended. With no page made for it (it failed, or made a terminal),
    /// its keys go on to whatever has focus; a page made keeps the hold until its readiness.
    func endIncoming(_ token: String?, pageMade: Bool) {
        guard let token, let (number, entry) = buffers.first(where: { $0.value.buffer.token == token }) else { return }
        guard !pageMade || entry.incoming?.claimed != true else { return }
        if let window = entry.window { release(in: window) } else { buffers[number] = nil }
    }

    /// A New Tab page `key` reported its field ready with `token`: the hold that gave it the token
    /// (in whatever window) sends its keys there.
    func pageReady(_ token: String, key: String) {
        guard let entry = buffers.values.first(where: { $0.buffer.token == token }), let window = entry.window else { return }
        entry.incoming?.key = key
        entry.buffer.acknowledge(token)
        flush(in: window)
    }

    private func deliver(in window: NSWindow) -> (NSEvent) -> Void {
        { [weak router, weak window] event in
            guard let router, let window else { return }
            router.dispatchingSynthetic(event) {
                if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
        }
    }

    private func install(_ entry: Entry, in window: NSWindow) {
        let number = window.windowNumber
        let buffer = entry.buffer
        entry.deadline = scheduleDeadline(entry.limit) { [weak self, weak buffer] in
            guard let self, let buffer else { return }
            deadlinePassed(number: number, buffer: buffer)
        }
        buffers[number] = entry
    }

    /// The open put the page's tab on screen: leaving it now ends the hold at once.
    func didShow(in window: NSWindow?) {
        guard let window else { return }
        buffers[window.windowNumber]?.shown = true
    }

    /// The opening failed: its keys go on to whatever has focus.
    func cancel(in window: NSWindow?) {
        guard let window else { return }
        release(in: window)
    }

    func capture(_ event: NSEvent, in keyWindow: NSWindow?) -> Bool {
        // A Chromium page window is a child of the shell, whose number keys the hold.
        let window = keyWindow.map { router?.focus(for: $0).0?.window ?? $0 }
        // A chord (Cmd-V, Cmd-T, a menu key) never runs before keys typed ahead of it: the hold ends
        // and they go on first.
        if let window, let entry = buffers[window.windowNumber], !entry.buffer.replaying,
           KeyRouter.isChord(event.modifierFlags), entry.buffer.hasPending {
            release(in: window)
            return false
        }
        // Text and Delete wait; any other plain key (Return, Tab, an arrow, Escape) waits only behind
        // held keys, so it never runs before the text typed ahead of it.
        guard let router, let window, let entry = buffers[window.windowNumber],
              !KeyRouter.isChord(event.modifierFlags),
              KeyRouter.isPrintable(event) || event.keyCode == KeyRouter.deleteKeyCode || entry.buffer.hasPending
        else { return false }
        guard !entry.buffer.replaying else { return false }
        let (controller, kind) = router.focus(for: keyWindow)
        guard kind == .content, controller != nil else {
            // Focus left the content (a sidebar or bar field): held text goes on first, in order.
            if entry.buffer.hasPending { release(in: window) }
            return false
        }
        // The hold ended: the held keys go on first, then this one, in typing order.
        if expired(entry) || !entry.owns {
            release(in: window)
            return false
        }
        return entry.buffer.capture(event)
    }

    func acknowledge(_ token: String, in window: NSWindow?) {
        guard let window else { return }
        buffers[window.windowNumber]?.buffer.acknowledge(token)
        flush(in: window)
    }

    func flush(in window: NSWindow?) {
        guard let window, let entry = buffers[window.windowNumber] else { return }
        if entry.buffer.drain() {
            entry.deadline?.cancel()
            if buffers[window.windowNumber]?.buffer === entry.buffer { buffers[window.windowNumber] = nil }
        } else if expired(entry) || !entry.owns {
            release(in: window)
        }
    }

    /// Ends the window's hold and gives its keys, in typing order, to whatever has focus.
    private func release(in window: NSWindow) {
        guard let entry = buffers.removeValue(forKey: window.windowNumber) else { return }
        entry.deadline?.cancel()
        entry.buffer.release()
    }

    /// The hold limit of `buffer` passed. Only that hold ends (a later opening in the window keeps
    /// its own), and it ends even when its window closed, so no entry outlives it.
    private func deadlinePassed(number: Int, buffer: NewTabInputBuffer) {
        guard let entry = buffers[number], entry.buffer === buffer else { return }
        guard let window = entry.window else {
            buffers[number] = nil  // the window is gone: its keys go with it
            return
        }
        flush(in: window)
    }

    private func expired(_ entry: Entry) -> Bool {
        now() - entry.buffer.began >= entry.limit
    }

    /// Whether `window` holds keys for an opening (debug and tests).
    func isHolding(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return buffers[window.windowNumber] != nil
    }
}
