import AppKit
import CmuxNextBrowser
import CmuxNextFocusUI
import CmuxNextWakeups
import Foundation

/// Link hints on a focused Chromium page (`f` follows, `F` opens a link in a
/// new browser split): the page script labels what is clickable on screen,
/// the key router hands this controller every key while labels show, and a
/// complete label clicks its element with trusted input (or opens its link).
/// The page never sees the hint letters. One session at a time; Escape, a
/// chord, any other key, a scroll or another window ends it.
@MainActor
final class LinkHintController {
    private struct Session {
        var keys: LinkHintSession
        weak var tab: CEFTab?
        weak var window: NSWindow?
        /// Whether this tab's page still has the keyboard in its window.
        let isFocused: () -> Bool
        let openInSplit: (URL) -> Void
        let notice: (String) -> Void
    }

    private var session: Session? { didSet { noteActive() } }
    /// The pending page call (collect, draw, narrow); a newer one replaces it.
    private var pending: Task<Void, any Error>?
    /// What runs with the pending call's value, on main; the task carries none of it.
    private var pendingThen: ((BrowserJSValue?) async -> Void)?
    /// Where the page calls run: each is the rest of the person's `f` or hint key, at user-blocking priority
    /// (Chrome's `TaskPriority::USER_BLOCKING` for input replies, base/task/task_traits.h).
    private let work: BackgroundWork

    init(work: BackgroundWork) {
        self.work = work
    }

    var isActive: Bool { session != nil }

    /// The key router's modes: while labels show, the router asks this controller first for typing keys too
    /// (``KeyRouterMode/linkHints``). `AppServices` passes the router's instance.
    var keyModes: KeyRouterModes? { didSet { noteActive() } }

    private func noteActive() { keyModes?.set(.linkHints, isActive) }

    func start(_ mode: LinkHintSession.Mode, tab: CEFTab, window: NSWindow?, isFocused: @escaping () -> Bool,
               openInSplit: @escaping (URL) -> Void, notice: @escaping (String) -> Void) {
        cancel()
        session = Session(keys: LinkHintSession(mode: mode), tab: tab, window: window, isFocused: isFocused,
                          openInSplit: openInSplit, notice: notice)
        call(LinkHintSession.collectScript, on: tab) { [weak self] value in
            self?.collected(value.map(LinkHintSession.targets(from:)) ?? [], from: tab)
        }
    }

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

    /// Every key-down while labels show (``KeyRouter`` asks first). Returns
    /// whether the key was consumed; a key that ends the session without
    /// being a hint key goes on, and so does every key once the page no
    /// longer has the keyboard (a terminal, a field, another window).
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard var current = session, let tab = current.tab, let home = current.window,
              window === home || window?.parent === home, current.isFocused() else {
            cancel()
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 53 {
            cancel()
            return true
        }
        let outcome: LinkHintSession.Outcome
        if flags.isEmpty, event.keyCode == 51 {
            outcome = current.keys.type(nil)
        } else if flags.isEmpty, let letter = event.charactersIgnoringModifiers?.lowercased(), letter.count == 1,
                  letter.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) {
            outcome = current.keys.type(letter)
        } else {
            cancel()
            return false
        }
        session = current
        apply(outcome, on: tab)
        return true
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        pendingThen = nil
        guard let tab = session?.tab else {
            session = nil
            return
        }
        session = nil
        // task-owner: BackgroundWork; one overlay removal nothing waits on and no later call cancels (recipe R-hop)
        work.task(.userBlocking) { _ = try? await tab.evaluate(LinkHintSession.removeScript, world: .isolated, gesture: .cmux) }
    }

    private func collected(_ targets: [LinkHintTarget], from tab: CEFTab) {
        guard var current = session, current.tab === tab else { return }
        let outcome = current.keys.show(targets)
        session = current
        if outcome == .cancel {
            current.notice(LinkHintStrings.noLinks)
            session = nil
            return
        }
        call(LinkHintSession.drawScript(current.keys.hints ?? []), on: tab) { [weak self] _ in self?.apply(outcome, on: tab) }
    }

    private func apply(_ outcome: LinkHintSession.Outcome, on tab: CEFTab) {
        guard let current = session else { return }
        switch outcome {
        case .cancel:
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

enum LinkHintStrings {
    static var noLinks: String {
        String(localized: "linkHints.notice.noLinks", defaultValue: "No links on screen", table: "LinkHints", bundle: .module)
    }

    static var engine: String {
        String(localized: "linkHints.refusal.engine", defaultValue: "Link hints work in Chromium pages.", table: "LinkHints", bundle: .module)
    }
}
