public import AppKit
public import CmuxNextInput
public import CmuxNextWakeups
import Foundation

/// Link hints on a focused Chromium page (`f` follows, `F` opens a link in a
/// new browser split): the page script labels what is clickable on screen,
/// the key router hands this controller every key while labels show, and a
/// complete label clicks its element with trusted input (or opens its link).
/// The page never sees the hint letters. One session at a time; Escape, a
/// chord, any other key, a scroll or another window ends it.
@MainActor
public final class LinkHintController {
    private struct Session {
        var keys: LinkHintSession
        weak var tab: CEFTab?
        weak var window: NSWindow?
        /// Whether this tab's page still has the keyboard in its window.
        let isFocused: () -> Bool
        let openInSplit: (URL) -> Void
        /// The page has nothing to label.
        let noLinks: () -> Void
        var pending = LinkHintPendingKeys<NSEvent>() // every key typed while the page answers, in order
    }

    private var session: Session? { didSet { noteActive() } }
    private var replays = LinkHintReplays<NSEvent>()
    private var seen = LinkHintSeenKeys<NSEvent>()
    /// The key-down the app dispatches now, and whether it dispatched it before (``noteKeyDown(_:)``).
    private var noted: (event: NSEvent, seen: Bool)?
    /// The bound of the page's answer: a page that never answers (a hung renderer) never keeps the keys typed meanwhile.
    private var bound: MainDeadline?
    /// Key-ups and clicks while the page answers (``inputWillDispatch(_:)``).
    private var input: InputSubscription?
    /// The pending page call (collect, draw, narrow); a newer one replaces it.
    private var pending: Task<Void, any Error>?
    /// What runs with the pending call's value, on main; the task carries none of it.
    private var pendingThen: ((BrowserJSValue?) async -> Void)?
    /// Where the page calls run: each is the rest of the person's `f` or hint key, at user-blocking priority
    /// (Chrome's `TaskPriority::USER_BLOCKING` for input replies, base/task/task_traits.h).
    private let work: BackgroundWork

    public init(work: BackgroundWork) {
        self.work = work
    }

    public var isActive: Bool { session != nil }

    /// Turns the key router's link-hint mode on and off: while a session runs, the router asks this controller first for
    /// typing keys too (``KeyRouterMode/linkHints``). `AppServices` sets it to the router's modes.
    public var activeChanged: ((Bool) -> Void)? { didSet { noteActive() } }

    private func noteActive() { activeChanged?(isActive) }

    /// Hears key-ups and clicks on `tap` before AppKit dispatches them, while a page answers; bounds the page's answer
    /// on `deadlines` (a person waits for it).
    public func listen(to tap: InputEventTap, deadlines: MainDeadlineScheduler) {
        bound = MainDeadline(owner: "LinkHintController.answer", workClass: .userBlocking, scheduler: deadlines)
        input = tap.subscribe(class: [.key, .button], phase: .intercept(order: .standard), while: { [weak self] in self?.session?.keys.hints == nil && self?.session != nil }) { [weak self] event in
            self?.inputWillDispatch(event) == true ? .consume : .pass
        }
    }

    /// Every key-down of the process, first (``KeyRouter``): whether the app dispatched it before. Chromium sends a key
    /// the page left unhandled through the app again; the page had it, so it is never a session's (v6 doubled "fiel").
    public func noteKeyDown(_ event: NSEvent) {
        noted = (event, seen.note(event, .init(time: event.timestamp, code: event.keyCode, characters: event.charactersIgnoringModifiers)))
    }

    /// A key-up or a click before AppKit dispatches it, while the page answers: a key-up whose key-down waits waits
    /// behind it (the page never gets an up before its down); a click gives the keys typed before it to the page first.
    public func inputWillDispatch(_ event: NSEvent) -> Bool {
        guard var current = session, current.keys.hints == nil, event.type != .keyDown else { return false }
        guard event.type == .keyUp else { if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { cancel() }; return false }
        defer { session = current }
        return current.pending.holdUp(event, code: event.keyCode)
    }

    public func start(_ mode: LinkHintSession.Mode, tab: CEFTab, window: NSWindow?, isFocused: @escaping () -> Bool,
                      openInSplit: @escaping (URL) -> Void, noLinks: @escaping () -> Void) {
        cancel()
        session = Session(keys: LinkHintSession(mode: mode), tab: tab, window: window, isFocused: isFocused,
                          openInSplit: openInSplit, noLinks: noLinks)
        askFocus(of: tab, began: ContinuousClock.now)
        bound?.schedule(after: .milliseconds(500)) { [weak self, weak tab] in
            if let tab { self?.collected(nil, from: tab) }
        }
    }

    /// The page's answer: whether a text field has the keyboard (the focused element only, ``LinkHintSession/focusScript``),
    /// then, only when none has, the targets (lead on STATUS 7898). The input journal gets each call's time.
    private func askFocus(of tab: CEFTab, began: ContinuousClock.Instant) {
        call(LinkHintSession.focusScript, on: tab) { [weak self] focus in
            guard let self, let focus else { self?.collected(nil, from: tab); return }
            let editing = LinkHintSession.editing(from: focus), checked = ContinuousClock.now
            tab.host.lifecycleTrace.record(tab.id, "link-hints focus-check \(Self.ms(checked - began)) editing=\(editing)")
            guard !editing else { return collected((true, []), from: tab) }
            call(LinkHintSession.collectScript, on: tab) { [weak self] value in
                let targets = value.map(LinkHintSession.targets(from:))
                tab.host.lifecycleTrace.record(tab.id, "link-hints targets \(Self.ms(ContinuousClock.now - checked)) count=\(targets?.count ?? -1)")
                self?.collected(targets.map { (false, $0) }, from: tab)
            }
        }
    }

    private static func ms(_ duration: Duration) -> String { String(format: "%.1fms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }

    /// Runs `script` in `tab`'s isolated world as the pending page call, replacing the one in flight, then `then` with
    /// its value (nil when it failed) unless a newer call or ``cancel()`` replaced it first.
    private func call(_ script: String, on tab: CEFTab, then: @escaping (BrowserJSValue?) async -> Void) {
        pending?.cancel()
        pendingThen = then
        // task-owner: LinkHintController.pending; a newer call or cancel() cancels it, quit skips it (recipe R-hop)
        pending = work.task(.userBlocking) { [weak self] in await self?.evaluate(script, on: tab) }
    }

    /// The pending page call of ``call(_:on:then:)``: CEFTab's evaluate, then its `then` unless a newer call or
    /// ``cancel()`` replaced it first.
    private func evaluate(_ script: String, on tab: CEFTab) async {
        let value = try? await tab.evaluate(script, world: .isolated, gesture: .cmux)
        guard !Task.isCancelled, let then = pendingThen else { return }
        pendingThen = nil
        await then(value)
    }

    /// Every key-down while a session runs (``KeyRouter`` asks first). Returns whether the key was consumed: before the
    /// page answers every key waits for it; once labels show a key that ends the session without being a hint key goes
    /// on, and so does every key once the page no longer has the keyboard (a terminal, a field, another window).
    public func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        if replays.isReplay(event) || (noted?.event === event && noted?.seen == true) { return false } // the page had it
        guard var current = session, let tab = current.tab, let home = current.window,
              window === home || window?.parent === home, current.isFocused() else { cancel(); return false }
        let kind = Self.kind(of: event)
        guard current.keys.hints != nil else { // the page has not answered: every key waits for its answer, in order
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
        pending?.cancel()
        pending = nil
        pendingThen = nil
        bound?.cancel()
        guard let current = session else { return }
        session = nil
        if current.keys.hints == nil { var held = current.pending; deliver(held.releaseAll()) }
        guard let tab = current.tab else { return }
        // task-owner: BackgroundWork; one overlay removal nothing waits on and no later call cancels (recipe R-hop)
        work.task(.userBlocking) { _ = try? await tab.evaluate(LinkHintSession.removeScript, world: .isolated, gesture: .cmux) }
    }

    /// The page answered (nil: its call failed or took past its bound).
    private func collected(_ answer: (editing: Bool, targets: [LinkHintTarget])?, from tab: CEFTab) {
        guard var current = session, current.tab === tab, current.keys.hints == nil else { return }
        bound?.cancel()
        guard let answer else { tab.host.lifecycleTrace.record(tab.id, "link-hints no answer: keys go to the page"); return cancel() }
        let resolved = current.pending.resolve(&current.keys, targets: answer.targets, editing: answer.editing)
        session = current
        defer { deliver(resolved.page) }
        if resolved.noLinks { current.noLinks() }
        guard resolved.outcome != .passThrough, resolved.outcome != .cancel else { session = nil; return }
        call(LinkHintSession.drawScript(current.keys.hints ?? []), on: tab) { [weak self] _ in self?.apply(resolved.outcome, on: tab) }
    }

    /// Gives `keys` to the page they were typed into, once each, in order; a session never takes them again.
    private func deliver(_ keys: [NSEvent]) {
        replays.mark(keys)
        for key in keys { if let window = key.window, window !== NSApp.keyWindow { window.sendEvent(key) } else { NSApp.sendEvent(key) } }
    }

    private func apply(_ outcome: LinkHintSession.Outcome, on tab: CEFTab) {
        guard let current = session else { return }
        switch outcome {
        case .cancel, .passThrough:
            cancel()
        case .narrow(let prefix):
            guard current.keys.hints != nil else { return }
            // A newer prefix wins over a draw or narrow still in flight.
            call(LinkHintSession.narrowScript(prefix), on: tab) { [weak self] shown in
                // The labels are gone (the page scrolled): end the session.
                if shown != .bool(true) { self?.cancel() }
            }
        case .pick(let target):
            session = nil
            call(LinkHintSession.removeScript, on: tab) { removed in
                // Labels a scroll removed mean stale positions: click nothing.
                guard removed == .bool(true) else { return }
                switch current.keys.mode {
                case .follow: await Self.click(target, in: tab)
                case .newSplit: if let url = target.href { current.openInSplit(url) }
                }
            }
        }
    }

    /// A trusted click at the target's center (viewport CSS pixels), like
    /// the user's own: links honor their target and page handlers run.
    private static func click(_ target: LinkHintTarget, in tab: CEFTab) async {
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
}
