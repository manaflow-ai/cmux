import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextPages
import Foundation

/// The keys of one seed of the tab keys fuzz. Each key is a key-down event through the app's key router
/// (`KeyRouter.interceptKeyDown`), as the app gets a key. The test makes each event: none comes from the system's
/// event queue, and no menu sees one.
@MainActor struct TabKeysKeyboard {
    let router: KeyRouter
    let window: NSWindow
    /// The time of the newest key event. Each key has its own time: the key router tells two key events apart by it.
    private var stamp = ProcessInfo.processInfo.systemUptime
    /// The repeat flag of the keys, from a stream of its own: the keys and the deliveries of a seed stay those of the
    /// seed's own stream.
    private var repeatFlags: TabKeysRandom
    /// The key with Command before this key, nil after a letter key: a held key repeats only itself.
    private var chordBefore: String?
    /// A seed of one held key: each key directly after the same key repeats. Else 1 of 2 such keys repeats.
    private let held: Bool
    /// What had the keyboard before the newest key or delivery: where a hold that ended in it gave its keys on.
    var before: NSResponder?
    /// The page that the key router queued a letter for before the newest key (``queueingPage()``), nil for none.
    private var queuedFor: String?

    init(router: KeyRouter, window: NSWindow, seed: UInt64, held: Bool) {
        self.router = router
        self.window = window
        self.held = held
        repeatFlags = TabKeysRandom(seed: seed ^ 0xA5A5_5A5A_1234_4321)
    }

    /// One key-down with Command. `refusal` is nil when the router took the key and ran `action` in the key's own
    /// call. Else it says what the router did.
    mutating func chord(_ characters: String, code: UInt16, action: ActionID) -> (refusal: String?, repeats: Bool) {
        let repeats = chordBefore == characters && (held || repeatFlags.next(in: 0...1) == 0)
        chordBefore = characters
        guard let event = keyDown(characters, code: code, flags: [.command], repeats: repeats) else {
            return ("no key event could be made", repeats)
        }
        let router = self.router, window = self.window
        let ranBefore = router.interceptions
        let taken = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
        // The router's record is of this key only when its count rose in the key's call.
        guard router.interceptions > ranBefore, let ran = router.lastInterception else {
            let what = taken ? "took the key and ran no action in the key's own call" : "passed the key on and ran no action"
            return ("the key router \(what)", repeats)
        }
        if ran.action != action { return ("the key router ran \(ran.action.rawValue), not \(action.rawValue)", repeats) }
        if !ran.ran { return ("the action was refused", repeats) }
        return (taken ? nil : "the key router ran the action and passed the key on", repeats)
    }

    /// One letter key. Nil: no event could be made. `taken`: the key router took the key.
    mutating func letter() -> (key: NSEvent, taken: Bool)? {
        chordBefore = nil
        guard let key = keyDown("x", code: 7, flags: [], repeats: false) else { return nil }
        let router = self.router, window = self.window
        return (key, router.dispatchingSynthetic(key) { router.interceptKeyDown(key, in: window) })
    }

    private mutating func keyDown(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, repeats: Bool) -> NSEvent? {
        stamp += 0.03
        before = window.firstResponder
        queuedFor = queueingPage()
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: stamp, windowNumber: window.windowNumber,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeats,
                                keyCode: code)
    }

    // MARK: A letter that the key router took again

    /// What the check says of a letter key that the key router took again when the window's hold gave it on.
    enum LetterVerdict {
        /// The letter waits in the router's type-ahead queue for a page of its own tab.
        case waits
        /// A difference of the product, as text. `lost`: the letter went to no view; else it went to another tab.
        case differs(String, lost: Bool)
        /// The check does not see where the letter went.
        case unseen
    }

    /// The name that the router's type-ahead queue has for the page of `tab` in `pane`; nil: no page with a field.
    func page(of tab: String, in pane: PaneController) -> String? {
        pane.existingContent(for: tab)?.inputReadiness.map { String(describing: ObjectIdentifier($0)) }
    }

    /// The page that the key router queues a letter for now: the page of the focused pane, when typing may wait for
    /// it and its field is not ready. This is the router's own condition (`KeyRouter.typesAhead`), read from the
    /// same state; the terminal case of that condition is not read. Nil: the router queues no letter now.
    private func queueingPage() -> String? {
        guard let controller = router.focus(for: window).0 else { return nil }
        let resolved = controller.focus.state.resolved
        guard resolved.mayQueueTyping, let pane = resolved.pane,
              let readiness = controller.content?.paneController(key: pane)?.currentContent?.inputReadiness, !readiness.isReady
        else { return nil }
        return String(describing: ObjectIdentifier(readiness))
    }

    /// Where the letter key for `tab` went, that the router took again when the hold ended with `end`. `ids`: the
    /// ids of `tab` in the strip of `pane`. With text in the queue the check reads the queue. With an empty queue
    /// after a key with Command, the check reads the page that the router queued for before that key: the hold gives
    /// its keys on in that key's call, and then the same call ends the queue. The check does not see the queue hold
    /// the letter in that case.
    func letterVerdict(tab: String, ids: [String], in pane: PaneController, end: String, atChord: Bool) -> LetterVerdict {
        let pages = Set(ids.compactMap { page(of: $0, in: pane) })
        let start = "the hold ended with no field ready (\(end)) and gave the letter key for \(tab) on; "
        if !router.typeAhead.text.isEmpty, let queue = router.typeAhead.surface {
            if pages.contains(queue) { return .waits }
            return .differs(start + "the key router has it in its type-ahead queue for a page of another tab.", lost: false)
        }
        guard atChord, let queue = queuedFor else { return .unseen }
        let whose = pages.contains(queue) ? "the page of \(tab)" : "a page of another tab"
        return .differs("the letter key for \(tab) is lost: " + start + "the key router queued typing for \(whose), whose field was not "
            + "ready, and this key with Command ended that queue in the same call, by the product's rule that a key that is not "
            + "typing ends the type-ahead queue. The check read the page before the key and the empty queue after it.", lost: true)
    }

    /// The text for a letter that the router took again where the check reads no queue and no page.
    static func unseen(_ tab: String, end: String) -> String {
        "the hold ended with no field ready (\(end)) and the key router took the letter key for \(tab) again: the check does not "
            + "see where it went."
    }

    /// The text for a letter that waited in the router's type-ahead queue for the page of `tab`, when that queue is empty.
    static func lostInQueue(_ tab: String, end: String, atChord: Bool) -> String {
        "the letter key for \(tab) is lost: the hold ended with no field ready (\(end)) and gave the letter key on, the key router "
            + "held it in its type-ahead queue for the page of \(tab), and that queue ended "
            + (atChord ? "at this key with Command, by the product's rule that a key that is not typing ends the type-ahead queue."
                : "with no key with Command (the focus left the page, or the queue dropped its text).")
    }
}
