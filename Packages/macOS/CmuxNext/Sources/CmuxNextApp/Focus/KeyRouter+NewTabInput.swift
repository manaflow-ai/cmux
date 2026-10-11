import AppKit

/// Owns the short interval between Cmd-T and the New Tab field's readiness acknowledgement.
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
        /// The tab the pane showed before Cmd-T: it counts as the opening only until the page shows.
        let opened: String?
        weak var pane: PaneController?
        weak var window: NSWindow?
        /// The open put the page's tab on screen (`didShow`).
        var shown = false
        var deadline: Task<Void, Never>?

        init(buffer: NewTabInputBuffer, opened: String?, pane: PaneController, window: NSWindow) {
            self.buffer = buffer
            self.opened = opened
            self.pane = pane
            self.window = window
        }

        /// Whether the opening still owns the window's keys: its pane, in its window, shows its New
        /// Tab page (or, until the page shows, the tab it showed before).
        var owns: Bool {
            guard let pane, let window, pane.view.window === window else { return false }
            guard let key = pane.currentTabKey else { return !shown }
            if pane.services.agentTabs.isNewTabPage(key) { return true }
            return !shown && key == opened
        }
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
        }, deliver: { [weak router, weak window] event in
            guard let router, let window else { return }
            router.dispatchingSynthetic(event) {
                if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
        })
        let entry = Entry(buffer: buffer, opened: pane.currentTabKey, pane: pane, window: window)
        let number = window.windowNumber
        entry.deadline = scheduleDeadline(holdLimit) { [weak self, weak buffer] in
            guard let self, let buffer else { return }
            deadlinePassed(number: number, buffer: buffer)
        }
        buffers[number] = entry
        return buffer.token
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

    func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
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
        let (controller, kind) = router.focus(for: window)
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
        now() - entry.buffer.began >= holdLimit
    }

    /// Whether `window` holds keys for an opening (debug and tests).
    func isHolding(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return buffers[window.windowNumber] != nil
    }
}
