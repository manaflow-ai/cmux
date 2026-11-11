public import AppKit
import CmuxNextWakeups
import Foundation

/// Link hints on a focused page of either engine (`f` follows, `F` opens a link in a
/// new browser split): the page script labels what is clickable on screen,
/// the key router hands this controller every key while labels show, and a
/// complete label clicks its element with trusted input (or opens its link).
/// The page never sees the hint letters. One session at a time; Escape, a
/// chord, any other key, a scroll or another window ends it.
@MainActor
public final class LinkHintController {
    private struct Session {
        /// This session among all of the controller's: a page answer, a bound or a task of an ended session never acts
        /// on a later one (review 6603845634 findings 2 and 3), whatever tab it is on.
        let id: Int
        var keys: LinkHintSession
        weak var tab: (any BrowserTab)?
        weak var window: NSWindow?
        /// Whether this tab's page still has the keyboard in its window.
        let isFocused: () -> Bool
        let openInSplit: (URL) -> Void
        /// The page has nothing to label.
        let noLinks: () -> Void
        var pending = LinkHintPendingKeys<NSEvent>() // every key typed while the page answers, in order
        /// The page said no text field has the keyboard: the keys are hint keys from now on, whatever the targets take.
        var noField = false
    }

    private var session: Session?
    private var lastSessionID = 0
    private var replays = LinkHintReplays<NSEvent>()
    private var seen = LinkHintSeenKeys()
    /// The key-down the app dispatches now, and whether it dispatched it before (``noteKeyDown(_:)``).
    private var noted: (event: NSEvent, seen: Bool)?
    /// The pending page call (collect, draw, narrow); a newer one replaces it.
    private var work: Task<Void, Never>?
    /// A decided pick (remove the labels, then click or open): the session has ended, so nothing cancels it, neither a
    /// click nor a new start (review 6603845634: a click during the labels' draw dropped the pick and left the labels).
    private var picking: Task<Void, Never>?
    /// The bound of the page's answer: a page that never answers (a hung renderer) never keeps the keys typed meanwhile.
    private let bound = DemandTimer(owner: "LinkHintController.answer")

    /// The page's answer to whether a text field has the keyboard (nil: the call failed); a test answers instead.
    var focusAnswer: @MainActor (any BrowserTab) async -> Bool? = LinkHintController.pageFocus
    /// The page's hint targets (nil: the call failed); a test answers instead.
    var targetsAnswer: @MainActor (any BrowserTab) async -> [LinkHintTarget]? = LinkHintController.pageTargets
    /// Gives keys to the page they were typed into, in order; a test records them instead.
    var send: @MainActor ([NSEvent]) -> Void = LinkHintController.dispatch
    /// Runs a label script (draw, narrow, remove) in `tab`'s page (nil: the call failed); a test answers instead.
    var script: @MainActor (any BrowserTab, String) async -> BrowserJSValue? = LinkHintController.pageScript
    /// How long the page may take to say whether a text field has the keyboard; a test that ends the wait itself sets it longer.
    var answerBound: Duration = .milliseconds(500)

    public init() {}

    public var isActive: Bool { session != nil }

    /// The notice a page with nothing to label shows.
    public static var noLinksNotice: String {
        String(localized: "linkHints.notice.noLinks", defaultValue: "No links on screen", bundle: .module)
    }

    public func start(_ mode: LinkHintSession.Mode, tab: any BrowserTab, window: NSWindow?, isFocused: @escaping () -> Bool,
                      openInSplit: @escaping (URL) -> Void, noLinks: @escaping () -> Void) {
        cancel()
        // The cancel gave held keys to the page, and one of them may have started a session (link hints on a chord): this
        // start is the newer action, so that session ends too. It holds no key: every key of that send is a replay.
        if session != nil { cancel() }
        lastSessionID += 1
        let id = lastSessionID
        session = Session(id: id, keys: LinkHintSession(mode: mode), tab: tab, window: window, isFocused: isFocused,
                          openInSplit: openInSplit, noLinks: noLinks)
        work = Task { [weak self] in
            guard let self else { return }
            let editing = await focusAnswer(tab)
            guard !Task.isCancelled, session?.id == id else { return }
            guard let editing, !editing else { return collected(editing.map { ($0, []) }, from: tab, session: id) }
            // No text field has the keyboard: the keys typed now are hint keys, the session's whatever the targets
            // take (a heavy page), and never a page's (review 6594559342: a page shortcut on a hint letter would run).
            bound.cancel()
            guard var current = session, current.id == id else { return }
            let early = current.pending.resolveNoField(&current.keys) // the held keys are hint keys now, handled live after
            current.noField = true
            session = current
            // The session ends before its keys go to the page: a delivered key may start link hints again (review 6599335161).
            if early.ended { cancel(); return deliver(early.page) } // noField: cancel() sends no held key
            deliver(early.page)
            let targets = await targetsAnswer(tab)
            guard !Task.isCancelled else { return }
            collected((false, targets ?? []), from: tab, session: id)
        }
        let fire = boundForCurrentSession()
        bound.schedule(after: answerBound) { @MainActor in fire() }
    }

    /// The bound of session `id`'s focus check passed. ``DemandTimer`` can run a fire it already took after ``cancel()``
    /// and a new ``start(_:tab:window:isFocused:openInSplit:noLinks:)``: a bound ends only its own session.
    func boundFired(session id: Int?) {
        guard let id, session?.id == id else { return }
        answerTimedOut()
    }

    /// What the current session's bound runs when it fires (a test fires an ended session's bound late).
    func boundForCurrentSession() -> @MainActor @Sendable () -> Void {
        let id = session?.id
        return { [weak self] in self?.boundFired(session: id) }
    }

    /// The page did not say within the bound whether a text field has the keyboard (a hung renderer, a closed tab): the
    /// keys typed meanwhile go to the page, in order.
    func answerTimedOut() {
        guard let current = session, current.keys.hints == nil, !current.noField else { return }
        if let tab = current.tab { Self.trace(tab, "link-hints no answer: keys go to the page") }
        cancel()
    }

    /// Every key-down of the process, first (``KeyRouter``): whether the app dispatched it before. Chromium sends a key
    /// the page left unhandled through the app again; the page had it, so it is never a session's (v6 doubled "fiel").
    /// Only a Chromium page window's keys can start a session or be sent back: any other key returns at once (lead on
    /// STATUS 8037: no work per key for a person who never uses link hints).
    public func noteKeyDown(_ event: NSEvent, in window: NSWindow?) { // perf-hot: 0.05ms key-dispatch (every key-down of the process; 0 allocations)
        // A page window is a child window; its class exists only once Chromium loaded, which can be after the first key
        // (review 6594559342): looked up each time (a C string, no allocation), never remembered as missing.
        guard let window, window.parent != nil, let pageClass = objc_lookUpClass("CefNSWindow"), window.isKind(of: pageClass) else { return noted = nil }
        noted = (event, seen.note(event, time: event.timestamp, code: event.keyCode))
    }

    /// A key-up or a click before the app dispatches it, while the page answers: a key-up whose key-down waits waits
    /// behind it (the page never gets an up before its down); a click gives the keys typed before it to the page first.
    public func inputWillDispatch(_ event: NSEvent) -> Bool {
        guard var current = session, current.keys.hints == nil else { return false }
        guard event.type == .keyUp else { cancel(); return false }
        defer { session = current }
        return current.pending.holdUp(event, code: event.keyCode)
    }

    /// Every key-down while a session runs (``KeyRouter`` asks first). Returns whether the key was consumed: before the
    /// page answers every key waits for it; once labels show a key that ends the session without being a hint key goes
    /// on, and so does every key once the page no longer has the keyboard (a terminal, a field, another window).
    public func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        if replays.isReplay(event) || (noted?.event === event && noted?.seen == true) { return false } // the page had it
        guard var current = session, let tab = current.tab, let home = current.window,
              window === home || window?.parent === home, current.isFocused() else { cancel(); return false }
        let kind = Self.kind(of: event)
        guard current.keys.hints != nil || current.noField else { // the page has not answered: every key waits for its answer
            current.pending.hold(event, kind: kind, code: event.keyCode)
            session = current
            return true
        }
        let outcome: LinkHintSession.Outcome
        switch kind {
        case .escape: cancel(); return true // Escape ends the session
        case .other: cancel(); return false
        case .backspace: outcome = current.keys.type(nil)
        case .letter(let letter): outcome = current.keys.type(letter)
        }
        session = current
        apply(outcome, on: tab)
        return true
    }

    /// How a session reads `event`: Escape, Backspace, a letter (no Command, Control or Option), or another key.
    private static func kind(of event: NSEvent) -> LinkHintPendingKeys<NSEvent>.Kind {
        if event.keyCode == 53 { return .escape }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return .other }
        if event.keyCode == 51 { return .backspace }
        guard let letter = event.charactersIgnoringModifiers?.lowercased(), letter.count == 1,
              letter.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return .other }
        return .letter(letter)
    }

    /// Ends the session. Before its page answered, the keys typed meanwhile go to the page, in order: none is lost.
    public func cancel() {
        work?.cancel()
        work = nil
        bound.cancel()
        guard let current = session else { return }
        session = nil
        if current.keys.hints == nil, !current.noField { var pending = current.pending; deliver(pending.releaseAll()) } // hint keys never
        guard let tab = current.tab else { return }
        // task-owner: fire-and-forget overlay removal; nothing waits on it.
        Task { [script] in _ = await script(tab, LinkHintSession.removeScript) }
    }

    private static func pageScript(_ tab: any BrowserTab, _ source: String) async -> BrowserJSValue? {
        try? await tab.evaluate(source, world: .isolated, gesture: .cmux)
    }

    /// Whether a text field of `tab`'s page has the keyboard: the focused element only (``LinkHintSession/focusScript``).
    /// The input journal gets the call's time.
    private static func pageFocus(_ tab: any BrowserTab) async -> Bool? {
        let clock = ContinuousClock(), began = clock.now
        guard let focus = try? await tab.evaluate(LinkHintSession.focusScript, world: .isolated, gesture: .cmux) else { return nil }
        let editing = LinkHintSession.editing(from: focus)
        trace(tab, "link-hints focus-check \(Self.ms(clock.now - began)) editing=\(editing)")
        return editing
    }

    /// `tab`'s page's hint targets (``LinkHintSession/collectScript``). The input journal gets the call's time.
    private static func pageTargets(_ tab: any BrowserTab) async -> [LinkHintTarget]? {
        let clock = ContinuousClock(), began = clock.now
        guard let value = try? await tab.evaluate(LinkHintSession.collectScript, world: .isolated, gesture: .cmux) else { return nil }
        let targets = LinkHintSession.targets(from: value)
        trace(tab, "link-hints targets \(Self.ms(clock.now - began)) count=\(targets.count)")
        return targets
    }

    private static func ms(_ duration: Duration) -> String { String(format: "%.1fms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }

    /// The page answered (nil: its focus check failed: the keys go to the page). With no text field, failed targets are none.
    private func collected(_ answer: (editing: Bool, targets: [LinkHintTarget])?, from tab: any BrowserTab, session id: Int) {
        guard var current = session, current.id == id, current.keys.hints == nil else { return }
        bound.cancel()
        guard let answer else { Self.trace(tab, "link-hints no answer: keys go to the page"); return cancel() }
        let resolved = current.pending.resolve(&current.keys, targets: answer.targets, editing: answer.editing)
        session = current
        defer { deliver(resolved.page) }
        if resolved.noLinks { current.noLinks() }
        guard resolved.outcome != .passThrough, resolved.outcome != .cancel else { session = nil; return }
        let draw = LinkHintSession.drawScript(current.keys.hints ?? [])
        // A label typed in full before the labels came is picked now: the keys after it are the page's at once, never
        // the session's while the labels draw (LinkHintControllerFuzzTests), and the pick acts after the draw.
        if case .pick(let target) = resolved.outcome {
            session = nil
            picking = Task { [weak self, script] in
                _ = await script(tab, draw)
                await self?.pick(target, of: current, in: tab)
            }
            return
        }
        work = Task { [weak self, script] in
            _ = await script(tab, draw)
            guard !Task.isCancelled, let self else { return }
            apply(resolved.outcome, on: tab)
        }
    }

    /// Gives `keys` to the page they were typed into, once each, in order; a session never takes them again. No keys:
    /// nothing is marked. A sent key can start link hints again, twice in one send (a chord): the first new session ends
    /// with no keys inside the send, and its empty send must not unmark the rest of it (LinkHintControllerFuzzTests:
    /// the key after the second chord was taken by the third session).
    private func deliver(_ keys: [NSEvent]) {
        guard !keys.isEmpty else { return }
        replays.mark(keys)
        send(keys)
    }

    /// Each key through the app's dispatch, to the window it was typed into.
    private static func dispatch(_ keys: [NSEvent]) {
        for key in keys { if let window = key.window, window !== NSApp.keyWindow { window.sendEvent(key) } else { NSApp.sendEvent(key) } }
    }

    private func apply(_ outcome: LinkHintSession.Outcome, on tab: any BrowserTab) {
        guard let current = session else { return }
        switch outcome {
        case .cancel, .passThrough:
            cancel()
        case .narrow(let prefix):
            guard current.keys.hints != nil else { return }
            // A newer prefix wins over a draw or narrow still in flight.
            work?.cancel()
            work = Task { [weak self, script] in
                let shown = await script(tab, LinkHintSession.narrowScript(prefix))
                guard !Task.isCancelled, shown != .bool(true) else { return }
                // The labels are gone (the page scrolled): end the session.
                self?.cancel()
            }
        case .pick(let target):
            session = nil
            work?.cancel()
            work = nil
            picking = Task { [weak self] in await self?.pick(target, of: current, in: tab) }
        }
    }

    /// Removes the labels, then clicks `target` or opens its link. Labels a scroll removed mean stale positions: nothing.
    private func pick(_ target: LinkHintTarget, of ended: Session, in tab: any BrowserTab) async {
        guard await script(tab, LinkHintSession.removeScript) == .bool(true) else { return }
        switch ended.keys.mode {
        case .follow: await Self.click(target, in: tab)
        case .newSplit: if let url = target.href { ended.openInSplit(url) }
        }
    }

    /// The input journal of a Chromium tab (WebKit tabs keep none).
    private static func trace(_ tab: any BrowserTab, _ line: String) {
        (tab as? CEFTab)?.host.lifecycleTrace.record(tab.id, line)
    }

    /// A click at the target's center (viewport CSS pixels), like the user's own: links honor their
    /// target and page handlers run.
    private static func click(_ target: LinkHintTarget, in tab: any BrowserTab) async {
        guard let tab = tab as? CEFTab else { return await clickInPage(target, in: tab) }
        // A native click (fork API 29) opens no DevTools session: the tab's renderer stays shareable.
        if tab.sendClick(x: target.x * tab.emulationInputScale, y: target.y * tab.emulationInputScale) { return }
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            let pressed = type != "mouseMoved"
            _ = try? await tab.devTools(method: "Input.dispatchMouseEvent", params: [
                // View points under a fit's or device's scale (cx-mogig), as the browser host converts agent input.
                "type": type, "x": target.x * tab.emulationInputScale, "y": target.y * tab.emulationInputScale, "button": pressed ? "left" : "none", "clickCount": pressed ? 1 : 0,
            ])
        }
    }

    /// WebKit has no trusted click from the host: the person's command clicks the element at the
    /// target's center as a user gesture (a `target=_blank` link opens its tab, a field takes
    /// the keyboard).
    private static func clickInPage(_ target: LinkHintTarget, in tab: any BrowserTab) async {
        _ = try? await tab.evaluate(LinkHintSession.clickScript(target), world: .isolated, gesture: .agent)
    }
}
