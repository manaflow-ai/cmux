public import AppKit
import CmuxNextWakeups
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

    private var session: Session?
    private var replays = LinkHintReplays<NSEvent>()
    private var seen = LinkHintSeenKeys()
    /// The key-down the app dispatches now, and whether it dispatched it before (``noteKeyDown(_:)``).
    private var noted: (event: NSEvent, seen: Bool)?
    /// The pending page call (collect, draw, narrow); a newer one replaces it.
    private var work: Task<Void, Never>?
    /// The bound of the page's answer: a page that never answers (a hung renderer) never keeps the keys typed meanwhile.
    private let bound = DemandTimer(owner: "LinkHintController.answer")

    /// The page's answer to whether a text field has the keyboard (nil: the call failed); a test answers instead.
    var focusAnswer: @MainActor (CEFTab) async -> Bool? = LinkHintController.pageFocus
    /// The page's hint targets (nil: the call failed); a test answers instead.
    var targetsAnswer: @MainActor (CEFTab) async -> [LinkHintTarget]? = LinkHintController.pageTargets
    /// Gives keys to the page they were typed into, in order; a test records them instead.
    var send: @MainActor ([NSEvent]) -> Void = LinkHintController.dispatch

    public init() {}

    public var isActive: Bool { session != nil }

    public func start(_ mode: LinkHintSession.Mode, tab: CEFTab, window: NSWindow?, isFocused: @escaping () -> Bool,
                      openInSplit: @escaping (URL) -> Void, noLinks: @escaping () -> Void) {
        cancel()
        session = Session(keys: LinkHintSession(mode: mode), tab: tab, window: window, isFocused: isFocused,
                          openInSplit: openInSplit, noLinks: noLinks)
        work = Task { [weak self] in
            guard let self else { return }
            let answer = await answer(of: tab)
            guard !Task.isCancelled else { return }
            collected(answer, from: tab)
        }
        bound.schedule(after: .milliseconds(500)) { @MainActor [weak self] in self?.answerTimedOut() }
    }

    /// The page did not answer within the bound.
    func answerTimedOut() {
        if let tab = session?.tab { collected(nil, from: tab) }
    }

    /// Every key-down of the process, first (``KeyRouter``): whether the app dispatched it before. Chromium sends a key
    /// the page left unhandled through the app again; the page had it, so it is never a session's (v6 doubled "fiel").
    /// Only a Chromium page window's keys can start a session or be sent back: any other key returns at once (lead on
    /// STATUS 8037: no work per key for a person who never uses link hints).
    public func noteKeyDown(_ event: NSEvent, in window: NSWindow?) { // perf-hot: 0.05ms key-dispatch (every key-down of the process; 0 allocations)
        guard let pageWindowClass = Self.pageWindowClass, window?.isKind(of: pageWindowClass) == true else { return noted = nil }
        noted = (event, seen.note(event, time: event.timestamp, code: event.keyCode))
    }

    /// Chromium's page window class (`CefNSWindow`), looked up once.
    private static let pageWindowClass: AnyClass? = NSClassFromString("CefNSWindow")

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
        work?.cancel()
        work = nil
        bound.cancel()
        guard let current = session else { return }
        session = nil
        if current.keys.hints == nil { var pending = current.pending; deliver(pending.releaseAll()) }
        guard let tab = current.tab else { return }
        // task-owner: fire-and-forget overlay removal; nothing waits on it.
        Task { _ = try? await tab.evaluate(LinkHintSession.removeScript, world: .isolated, gesture: .cmux) }
    }

    /// The page's answer: whether a text field has the keyboard (``focusAnswer``), then, only when none has, the targets
    /// (``targetsAnswer``). Nil when a call failed.
    private func answer(of tab: CEFTab) async -> (editing: Bool, targets: [LinkHintTarget])? {
        guard let editing = await focusAnswer(tab) else { return nil }
        guard !editing else { return (true, []) }
        guard let targets = await targetsAnswer(tab) else { return nil }
        return (false, targets)
    }

    /// Whether a text field of `tab`'s page has the keyboard: the focused element only (``LinkHintSession/focusScript``).
    /// The input journal gets the call's time.
    private static func pageFocus(_ tab: CEFTab) async -> Bool? {
        let clock = ContinuousClock(), began = clock.now
        guard let focus = try? await tab.evaluate(LinkHintSession.focusScript, world: .isolated, gesture: .cmux) else { return nil }
        let editing = LinkHintSession.editing(from: focus)
        tab.host.lifecycleTrace.record(tab.id, "link-hints focus-check \(Self.ms(clock.now - began)) editing=\(editing)")
        return editing
    }

    /// `tab`'s page's hint targets (``LinkHintSession/collectScript``). The input journal gets the call's time.
    private static func pageTargets(_ tab: CEFTab) async -> [LinkHintTarget]? {
        let clock = ContinuousClock(), began = clock.now
        guard let value = try? await tab.evaluate(LinkHintSession.collectScript, world: .isolated, gesture: .cmux) else { return nil }
        let targets = LinkHintSession.targets(from: value)
        tab.host.lifecycleTrace.record(tab.id, "link-hints targets \(Self.ms(clock.now - began)) count=\(targets.count)")
        return targets
    }

    private static func ms(_ duration: Duration) -> String { String(format: "%.1fms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }

    /// The page answered (nil: its call failed or took past its bound).
    private func collected(_ answer: (editing: Bool, targets: [LinkHintTarget])?, from tab: CEFTab) {
        guard var current = session, current.tab === tab, current.keys.hints == nil else { return }
        bound.cancel()
        guard let answer else { tab.host.lifecycleTrace.record(tab.id, "link-hints no answer: keys go to the page"); return cancel() }
        let resolved = current.pending.resolve(&current.keys, targets: answer.targets, editing: answer.editing)
        session = current
        defer { deliver(resolved.page) }
        if resolved.noLinks { current.noLinks() }
        guard resolved.outcome != .passThrough, resolved.outcome != .cancel else { session = nil; return }
        let draw = LinkHintSession.drawScript(current.keys.hints ?? [])
        work = Task { [weak self] in
            _ = try? await tab.evaluate(draw, world: .isolated, gesture: .cmux)
            guard !Task.isCancelled else { return }
            self?.apply(resolved.outcome, on: tab)
        }
    }

    /// Gives `keys` to the page they were typed into, once each, in order; a session never takes them again.
    private func deliver(_ keys: [NSEvent]) {
        replays.mark(keys)
        send(keys)
    }

    /// Each key through the app's dispatch, to the window it was typed into.
    private static func dispatch(_ keys: [NSEvent]) {
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
            work?.cancel()
            work = Task { [weak self] in
                let shown = try? await tab.evaluate(LinkHintSession.narrowScript(prefix), world: .isolated, gesture: .cmux)
                guard !Task.isCancelled, shown != .bool(true) else { return }
                // The labels are gone (the page scrolled): end the session.
                self?.cancel()
            }
        case .pick(let target):
            session = nil
            work?.cancel()
            work = Task {
                // Labels a scroll removed mean stale positions: click nothing.
                guard (try? await tab.evaluate(LinkHintSession.removeScript, world: .isolated, gesture: .cmux)) == .bool(true) else { return }
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
