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

    private struct Entry {
        let buffer: NewTabInputBuffer
        /// Whether the opening still owns the window's keys (its pane still shows its New Tab page).
        let owns: () -> Bool
        let deadline: Task<Void, Never>
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
        let opened = pane.currentTabKey
        let owns: () -> Bool = { [weak pane, weak window] in
            guard let pane, let window, pane.view.window === window else { return false }
            // Until the open shows its tab the pane still shows what it had (`opened`).
            guard let key = pane.currentTabKey else { return true }
            return key == opened || pane.services.agentTabs.isNewTabPage(key)
        }
        let deadline = scheduleDeadline(holdLimit) { [weak self, weak window] in self?.flush(in: window) }
        buffers[window.windowNumber] = Entry(buffer: buffer, owns: owns, deadline: deadline)
        return buffer.token
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
        let (controller, kind) = router.focus(for: window)
        guard kind == .content, controller != nil else { return false }
        guard !entry.buffer.replaying else { return false }
        // The hold ended: the held keys go on first, then this one, in typing order.
        if expired(entry) || !entry.owns() {
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
            entry.deadline.cancel()
            if buffers[window.windowNumber]?.buffer === entry.buffer { buffers[window.windowNumber] = nil }
        } else if expired(entry) || !entry.owns() {
            release(in: window)
        }
    }

    /// Ends the window's hold and gives its keys, in typing order, to whatever has focus.
    private func release(in window: NSWindow) {
        guard let entry = buffers.removeValue(forKey: window.windowNumber) else { return }
        entry.deadline.cancel()
        entry.buffer.release()
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
