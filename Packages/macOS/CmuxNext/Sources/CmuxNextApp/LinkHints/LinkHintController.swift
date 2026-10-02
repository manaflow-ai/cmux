import AppKit
import CmuxNextBrowser
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
        let openInSplit: (URL) -> Void
        let notice: (String) -> Void
    }

    private var session: Session?
    /// The pending page call (collect, draw, narrow); a newer one replaces it.
    private var work: Task<Void, Never>?

    var isActive: Bool { session != nil }

    func start(_ mode: LinkHintSession.Mode, tab: CEFTab, window: NSWindow?,
               openInSplit: @escaping (URL) -> Void, notice: @escaping (String) -> Void) {
        cancel()
        session = Session(keys: LinkHintSession(mode: mode), tab: tab, window: window, openInSplit: openInSplit, notice: notice)
        work = Task { [weak self] in
            let value = try? await tab.evaluate(LinkHintScript.collect, world: .isolated)
            guard !Task.isCancelled else { return }
            self?.collected(value.map(LinkHintScript.targets(from:)) ?? [], from: tab)
        }
    }

    /// Every key-down while labels show (``KeyRouter`` asks first). Returns
    /// whether the key was consumed; a key that ends the session without
    /// being a hint key goes on.
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard var current = session, let tab = current.tab,
              window === current.window || window?.parent === current.window else {
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
        work?.cancel()
        work = nil
        guard let tab = session?.tab else {
            session = nil
            return
        }
        session = nil
        // task-owner: fire-and-forget overlay removal; nothing waits on it.
        Task { _ = try? await tab.evaluate(LinkHintScript.remove, world: .isolated) }
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
        let draw = LinkHintScript.draw(current.keys.hints ?? [])
        work = Task { [weak self] in
            _ = try? await tab.evaluate(draw, world: .isolated)
            guard !Task.isCancelled else { return }
            self?.apply(outcome, on: tab)
        }
    }

    private func apply(_ outcome: LinkHintSession.Outcome, on tab: CEFTab) {
        guard let current = session else { return }
        switch outcome {
        case .cancel:
            cancel()
        case .narrow(let prefix):
            guard current.keys.hints != nil else { return }
            work = Task { [weak self] in
                let shown = try? await tab.evaluate(LinkHintScript.narrow(prefix), world: .isolated)
                guard !Task.isCancelled, shown != .bool(true) else { return }
                // The labels are gone (the page scrolled): end the session.
                self?.cancel()
            }
        case .pick(let target):
            session = nil
            work?.cancel()
            work = Task {
                // Labels a scroll removed mean stale positions: click nothing.
                guard (try? await tab.evaluate(LinkHintScript.remove, world: .isolated)) == .bool(true) else { return }
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
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            let pressed = type != "mouseMoved"
            _ = try? await tab.devTools(method: "Input.dispatchMouseEvent", params: [
                "type": type, "x": target.x, "y": target.y, "button": pressed ? "left" : "none", "clickCount": pressed ? 1 : 0,
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
