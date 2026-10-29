import AppKit
import CmuxNextActions
import CmuxNextFocusUI
import CmuxNextInput
import CmuxNextAgentPane
import CmuxNextDesign

/// Owns the short interval between Cmd-T (or Cmd-N's new workspace) and the New Tab field's
/// readiness acknowledgement: every key typed from the shortcut on waits here, in order, and goes to
/// the field once it reported ready (cx-kql5h: after Cmd-N the first 2-3 keys went to the old
/// workspace, because nothing held them while the workspace and its page were made).
///
/// The keys wait in the window's one ``WindowInputQueue``, stamped with the page's field
/// (principled audit, lagFirstKey), and go only to that field. No timer ends the hold and no key is
/// given to whatever has focus. The hold ends, dropping the keys still waiting with a logged reason, when
/// - its pane no longer shows a New Tab page (the page was left or became a chat) or left the
///   window, or the window closed,
/// - its creation failed or its page closed before it existed,
/// - the person moved on: another opening (its keys stay with the first page unless a held key opened it),
///   Escape, a click on another pane, a key window that is not the shell's.
/// A close key (Cmd-W) acts at once and drops the keys. Any other key waits behind keys already held, so it never
/// runs before the text typed ahead of it (nightly 2026-10-11, "cannot type at all", was the old bound's reason:
/// Escape or a click now ends a hold whose field never comes).
@MainActor
final class NewTabInputCoordinator {
    weak var router: KeyRouter?
    /// The router's typing keys come here only while some window holds keys (``KeyRouterMode/newTabCapture``).
    private var buffers: [Int: Entry] = [:] { didSet { router?.modes.set(.newTabCapture, !buffers.isEmpty) } }
    /// The log's clock (an entry's age in `debug.focus`); nothing else reads time here.
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    private final class Entry {
        let buffer: NewTabInputBuffer
        /// The tab the pane showed before Cmd-T: it counts as the opening only until the page shows.
        let opened: String?
        weak var pane: PaneController?
        weak var window: NSWindow?
        /// The open put the page's tab on screen (`didShow`).
        var shown = false
        /// A page that does not exist yet (Cmd-N's new workspace, `beginIncoming`): its tab key
        /// comes with its readiness; until then the hold owns its window's keys.
        let incoming: IncomingPage?

        init(buffer: NewTabInputBuffer, opened: String?, pane: PaneController?, window: NSWindow, incoming: IncomingPage? = nil) {
            self.buffer = buffer
            self.opened = opened
            self.pane = pane
            self.window = window
            self.incoming = incoming
        }

        /// Whether the opening still owns the window's keys: its pane, in its window, shows its New
        /// Tab page (or, until the page shows, the tab it showed before). An incoming page's hold
        /// owns them until its readiness or its creation's end.
        var owns: Bool {
            guard let window else { return false }
            if incoming != nil { return true }
            guard let pane, pane.view.window === window, pane.view.isShownForInput else { return false }
            guard let key = pane.currentTabKey else { return !shown }
            if pane.services.agentTabs.isNewTabPage(key) { return true }
            return !shown && key == opened
        }
    }

    /// The page an incoming hold waits for: its token rides on the new workspace's first New Tab page
    /// (`WorkspaceSpawn.inputToken`, `attachIncoming`), and its tab key arrives with its readiness.
    final class IncomingPage {
        var key: String?
        var claimed = false
        /// New Window: the hold takes every window's keys and follows the page to its new window.
        var followsNewWindow = false
        weak var pageWindow: NSWindow?
        /// The page's view at readiness (a split's provisional key stops resolving later).
        weak var view: AgentPaneView?
    }

    init(router: KeyRouter) { self.router = router }

    /// Whether a hold's `window` may take the key window to give its field the keys: only from a
    /// window it owns (its Chromium page window), or when no window is key.
    static func mayTakeKey(_ window: NSWindow, keyWindow: NSWindow?) -> Bool {
        guard let keyWindow else { return true }
        var current: NSWindow? = keyWindow
        while let candidate = current {
            if candidate === window { return true }
            current = candidate.sheetParent ?? candidate.parent
        }
        return false
    }

    /// A New Window hold is waiting: it takes every window's keys until its page shows.
    var followsNewWindow: Bool { buffers.values.contains { $0.incoming?.followsNewWindow == true } }

    /// The last hold events (begin, capture, drain, end and why), for `debug.focus`.
    private(set) var log: [String] = []
    private func note(_ event: String, _ entry: Entry?) {
        let age = entry.map { " +\(Int((now() - $0.buffer.began) / .milliseconds(1)))ms" } ?? ""
        log.append("\(event)\(age)")
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    func begin(for pane: PaneController) -> String? {
        guard let router, let window = pane.view.window else { return nil }
        // The pane focus had at the opening, when the opening may move focus (a person's, not a script's).
        var focusedAtOpening = ActionRunScope.viewChangeAllowed() ? pane.services.windowController(showing: pane)?.focus.state.pane : nil
        let buffer = NewTabInputBuffer(began: now(), queue: router.inputQueues.queue(for: window.windowNumber), focusField: { [weak pane, weak window] in
            guard let pane, let window, let key = pane.currentTabKey, pane.services.agentTabs.isNewTabPage(key),
                  let view = pane.services.agentTabs.existingView(key), view.window === window,
                  view.isShownForInput else { return false }
            // A Chromium page window may be key: the shell takes it back, so later keys follow.
            // Never from another cmux window the person moved to since Cmd-T: their keys go there.
            // A Chromium page's own grant moves the keys to its page window: the shell does not take
            // them first (one key-window change, #24913).
            if !window.isKeyWindow, NSApp.isActive {
                guard Self.mayTakeKey(window, keyWindow: NSApp.keyWindow) else { return false }
                if view.chromiumPage == nil { window.makeKey() }
            }
            // The window refuses a page's web view outside an input event and the focus model's own
            // moves while the model names another pane (AgentPaneView.refusesSelfFocus), and the
            // readiness is neither. A page opened cold in a pane focus had not reached (another
            // pane's +: no spare, so no `focusPane`) never drained: its keys waited for the limit and
            // went to the old pane. The model moves first, as the responder change would tell it: once,
            // and only while focus is still where the opening left it (a click elsewhere since then wins).
            if let focus = pane.services.windowController(showing: pane)?.focus, let from = focusedAtOpening, from != pane.paneKey, focus.state.pane == from {
                focusedAtOpening = nil
                focus.send(.focusPane(pane.paneKey, source: .programmatic))
            }
            // A Chromium page takes the keys in its own window (a child of this one).
            if view.chromiumPage != nil {
                view.focusChat()
                return true
            }
            return window.makeFirstResponder(view.focusTarget)
        }, deliver: deliver(in: window))
        let entry = Entry(buffer: buffer, opened: pane.currentTabKey, pane: pane, window: window)
        install(entry, in: window)
        note("begin page opened=\(pane.currentTabKey ?? "-")", entry)
        return buffer.token
    }

    /// Cmd-N (a person's new workspace on the New Tab page, shown in `window`): from this moment
    /// every key of `window` waits for the new page's field. The new workspace's first New Tab page
    /// carries the token (`WorkspaceSpawn.inputToken`); its readiness names its tab and sends the keys there. The
    /// creation ends the hold when it fails or makes no page (`endIncoming`).
    func beginIncoming(in window: NSWindow?, followsNewWindow: Bool = false) -> String? {
        guard let router, let window else { return nil }
        let target = IncomingPage()
        target.followsNewWindow = followsNewWindow
        let services = router.services
        let buffer = NewTabInputBuffer(began: now(), queue: router.inputQueues.queue(for: window.windowNumber), focusField: { [weak services, weak window] in
            // The page shows in this window (FirstTabHold), or a New Window's, before it takes keys.
            guard let services, let window, let key = target.key,
                  let view = target.view ?? (services.agentTabs.isNewTabPage(key) ? services.agentTabs.existingView(key) : nil),
                  view.model.newTab != nil, let shown = view.window,
                  shown === window || target.followsNewWindow, view.isShownForInput else { return false }
            // A Chromium page window or the old window may be key: the page's window takes it. A
            // Chromium page's grant (below) moves the keys itself: one key-window change (#24913).
            if !shown.isKeyWindow, NSApp.isActive, view.chromiumPage == nil { shown.makeKey() }
            target.pageWindow = shown
            if view.chromiumPage != nil {
                view.focusChat()
                return true
            }
            return shown.makeFirstResponder(view.focusTarget)
        }, deliver: { [weak router, weak window] event in
            // The page's window (its field took the keys there); a New Window's page: the key window.
            guard let router, let to = target.pageWindow ?? (target.followsNewWindow ? NSApp.keyWindow : nil) ?? window else { return }
            Self.replay(Self.retarget(event, to: to), held: event, in: to, router: router)
        })
        let entry = Entry(buffer: buffer, opened: nil, pane: nil, window: window, incoming: target)
        install(entry, in: window)
        note("begin incoming", entry)
        return buffer.token
    }

    /// A New Tab page took the incoming hold's `token` (the page of the workspace its Cmd-N made):
    /// the creation's end keeps the hold until that page's readiness.
    func attachIncoming(_ token: String) {
        buffers.values.first(where: { $0.buffer.token == token })?.incoming?.claimed = true
    }

    /// Every window's hold tries to drain (a page joined its window: FirstTabHold).
    func flushAll() {
        for entry in Array(buffers.values) { flush(in: entry.window) }
    }

    /// The creation behind `token` ended. With no page made for it (it failed, or made a terminal),
    /// its keys drop (the field they were typed for never comes); a page made keeps the hold until its readiness.
    func endIncoming(_ token: String?, pageMade: Bool) {
        guard let token, let entry = buffers.values.first(where: { $0.buffer.token == token }) else { return }
        guard !pageMade || entry.incoming?.claimed != true else { return }
        end(entry, .targetFailed, why: "creation made no page")
    }

    /// A New Tab page `key` reported its field ready with `token`: the hold that gave it the token
    /// (in whatever window) sends its keys there.
    func pageReady(_ token: String, key: String) {
        guard let entry = buffers.values.first(where: { $0.buffer.token == token }), let window = entry.window else { return }
        entry.incoming?.key = key
        entry.incoming?.view = router?.services?.agentTabs.existingView(key)
        note("ready incoming \(key)", entry)
        entry.buffer.acknowledge(token)
        flush(in: window)
    }

    /// `event` as typed into `window` (a key held in one window and replayed in another).
    private static func retarget(_ event: NSEvent, to window: NSWindow) -> NSEvent {
        guard event.windowNumber != window.windowNumber,
              let moved = NSEvent.keyEvent(with: event.type, location: .zero, modifierFlags: event.modifierFlags,
                                           timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                                           characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                           isARepeat: event.isARepeat, keyCode: event.keyCode) else { return event }
        return moved
    }

    /// `window`'s hold, else a New Window hold, which takes every window's keys until its page shows.
    private func entry(for window: NSWindow) -> Entry? {
        buffers[window.windowNumber] ?? buffers.values.first { $0.incoming?.followsNewWindow == true }
    }

    private func remove(_ entry: Entry) { buffers = buffers.filter { $0.value !== entry } }

    private func deliver(in window: NSWindow) -> (NSEvent) -> Void {
        { [weak router, weak window] event in
            guard let router, let window else { return }
            Self.replay(event, held: event, in: window, router: router)
        }
    }

    /// Sends a held key on to `window` as `CmuxApplication.sendEvent` would. The pane gesture monitor
    /// never saw it (the router took it before AppKit's dispatch; `NSWindow.sendEvent` runs no
    /// monitor), so the agent pane that gets it judges the person's original key (`held`) here: a
    /// Return typed before the New Tab field was ready still runs its terminal line (cx-hnpxh).
    /// The hold is recorded in the seam (``HeldKeyReplay``, held_by `newTab`).
    static func replay(_ event: NSEvent, held: NSEvent, in window: NSWindow, router: KeyRouter) {
        router.heldKeys.replay(held, heldBy: .newTab, keyWindow: window) { send in
            router.dispatchingSynthetic(event) {
                guard !router.interceptKeyDown(event, in: window) else { return }
                // A page in Chromium has the keys in its own window, a child of this one: the key window,
                // or (the app not active yet) the shown agent page's window.
                if let page = Self.chromiumPageWindow(in: window) {
                    Self.chromiumAgentPane(under: page, in: window)?.judge(held, eventWindow: page)
                    return send.window(page, event)
                }
                var view = window.firstResponder as? NSView
                while let current = view, !(current is AgentPaneView) { view = current.superview }
                (view as? AgentPaneView)?.judge(held, eventWindow: window)
                send.window(window, event)
            }
        }
    }

    /// The Chromium page window (a child of `window`) that takes `window`'s held keys: the key window
    /// when it is one, else the window of a shown agent page in Chromium whose view has the
    /// keyboard in its own window (it was focused while the app was not active). Nil with pages in
    /// the view tree (``PageSurface/views``): the page view is `window`'s first responder.
    private static func chromiumPageWindow(in window: NSWindow) -> NSWindow? {
        guard PageSurface.of(window) == .childWindows else { return nil }
        if let key = NSApp.keyWindow, key !== window, key.parent === window { return key }
        guard window.firstResponder === window || window.firstResponder == nil else { return nil }
        return window.childWindows?.first { child in
            child.isVisible && chromiumAgentPane(under: child, in: window).map { $0.isShownForInput } == true
        }
    }

    /// The agent pane in `window` whose Chromium page shows in `page` (its child window).
    private static func chromiumAgentPane(under page: NSWindow, in window: NSWindow) -> AgentPaneView? {
        let center = CGPoint(x: page.frame.midX, y: page.frame.midY)
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let pane = view as? AgentPaneView, let content = pane.chromiumPage?.contentView, let host = content.window,
               host.convertToScreen(content.convert(content.bounds, to: nil)).contains(center) { return pane }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// One opening at a time per window: an earlier one ends here. A held key of it that runs now (a Cmd-T typed
    /// before its field was ready) opened this one: the keys typed after it are this page's. Otherwise its keys were
    /// typed for its own page, which the person left: they drop.
    private func install(_ entry: Entry, in window: NSWindow) {
        if let earlier = self.entry(for: window) {
            if earlier.buffer.replaying { earlier.buffer.handOver(to: entry.buffer) }
            end(earlier, .focusMovedAway, why: "replaced")
        }
        buffers[window.windowNumber] = entry
    }

    /// `window` closed: its openings go with it (its queue dropped their keys).
    func windowClosed(_ window: NSWindow) {
        buffers = buffers.filter { $0.key != window.windowNumber && $0.value.window != nil }
    }

    /// The person acted in `window` (a click, a focus move of theirs, one of their actions): an opening whose pane the
    /// window's focus no longer names ends, and its keys drop. A key it runs again is not a new act.
    func personActed(in window: NSWindow?) {
        guard let window, let router, let entry = entry(for: window), !entry.buffer.replaying, let pane = entry.pane,
              let controller = router.focus(for: window).0, let focused = controller.focus.state.pane, focused != pane.paneKey else { return }
        end(entry, .focusMovedAway, why: "the person moved to pane \(focused)")
    }

    /// The open put the page's tab on screen: leaving it now ends the hold at once.
    func didShow(in window: NSWindow?) { if let window { buffers[window.windowNumber]?.shown = true } }

    /// The New Tab page `tab` this hold opened closed before the daemon made it: its held keys go with it.
    func drop(tab: String, in window: NSWindow?) {
        if let window, let entry = entry(for: window), entry.pane?.currentTabKey == tab { end(entry, .targetClosed, why: "closed before created") }
    }

    /// The opening failed: its keys drop.
    func cancel(in window: NSWindow?) {
        if let window, let entry = entry(for: window) { end(entry, .targetFailed, why: "open failed") }
    }

    func capture(_ event: NSEvent, in keyWindow: NSWindow?) -> Bool {
        guard let router, let keyWindow else { return false }
        let (controller, kind) = router.focus(for: keyWindow)
        // A Chromium page window is a child of the shell, whose number keys the hold.
        let window = controller?.window ?? keyWindow
        guard let entry = entry(for: window), !entry.buffer.replaying,
              router.inputQueues.existing(for: window.windowNumber)?.isDelivering != true else { return false }
        // Text and Delete wait; any other key (Return, Tab, an arrow, a chord) waits only behind held keys, so it never
        // runs before the text typed ahead of it.
        let typing = !KeyRouter.isChord(event.modifierFlags) && (KeyRouter.isPrintable(event) || event.keyCode == KeyRouter.deleteKeyCode)
        guard typing || entry.buffer.hasPending else { return false }
        guard kind == .content, let controller else {
            // A panel, popup or sheet has the keyboard: the person moved on from the page.
            note("pass key (focus \(kind))", entry)
            end(entry, .focusMovedAway, why: "focus left content")
            return false
        }
        // The opening's page is gone: its keys drop, and this key goes where the person is now.
        if !entry.owns {
            end(entry, .focusMovedAway, why: "not owned at key (tab \(entry.pane?.currentTabKey ?? "-"))")
            return false
        }
        // A close key (Cmd-W) acts now on what it closes; Escape is the person leaving the page's field: the keys typed
        // for it drop, and the key goes on.
        if CreationInputCoordinator.closes(event, in: window, controller: controller, router: router) {
            end(entry, .targetClosed, why: "close key")
            return false
        }
        if event.keyCode == ChordTracker.escapeKeyCode {
            end(entry, .focusMovedAway, why: "escape")
            return false
        }
        note("hold key #\(entry.buffer.count + 1)", entry)  // never characters: desync reports keep this log
        return entry.buffer.capture(event)
    }

    func acknowledge(_ token: String, in window: NSWindow?) {
        guard let window else { return }
        note("ready \(buffers[window.windowNumber]?.buffer.token == token ? "match" : "other")", buffers[window.windowNumber])
        buffers[window.windowNumber]?.buffer.acknowledge(token)
        flush(in: window)
    }

    func flush(in window: NSWindow?) {
        guard let window, let entry = entry(for: window) else { return }
        if entry.buffer.drain() {
            note("drained to field", entry)
            // A held key that ran may have opened another page (it replaced this entry).
            if buffers[window.windowNumber] === entry { remove(entry) }
        } else if !entry.owns {
            end(entry, .focusMovedAway, why: "not owned (tab \(entry.pane?.currentTabKey ?? "-"))")
        }
    }

    /// Ends `entry`'s hold: the keys still waiting for its field drop (`reason`), never go to another view.
    private func end(_ entry: Entry, _ reason: WindowInputQueue.DropReason, why: String) {
        remove(entry)
        note("end: \(why), \(entry.buffer.hasPending ? "\(entry.buffer.count) keys dropped (\(reason.rawValue))" : "no keys")", entry)
        entry.buffer.drop(reason)
    }

    /// Whether `window` holds keys for an opening (debug and tests).
    func isHolding(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return buffers[window.windowNumber] != nil
    }
}
