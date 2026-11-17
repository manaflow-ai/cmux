import AppKit
import CmuxNextActions
@testable import CmuxNextApp
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
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: stamp, windowNumber: window.windowNumber,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeats,
                                keyCode: code)
    }
}
