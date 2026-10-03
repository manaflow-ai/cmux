import AppKit
import CmuxNextActions

/// Two-key shortcuts (`["ctrl+b", "c"]` in cmux.json) for the key router:
/// the first key arms a chord in its window, and the next key-down there
/// completes it or ends it. As in the old app there is no timeout, and a
/// key in another window ends it.
///
/// The Cmd-J leader (`LeaderLayer`) is a chord prefix that arms whenever
/// some binding sits under it, even one that cannot run in this focus, so
/// its which-key overlay can say what Cmd-J offers. A key after it that
/// completes nothing (Escape, an unbound key, Cmd-J again) is dismissed:
/// it reaches no view, so a stray letter never types into the terminal.
/// Holding Cmd-J keeps it armed (key repeats are ignored), and a focus
/// change in its window ends it (`focusDidChange(to:in:)`).
struct ChordTracker {
    enum Step: Equatable {
        /// Not a chord key: route the event as usual.
        case pass
        /// The first key of a chord: consume it and wait.
        case armed
        /// The second key completed a chord: run its action.
        case run(ActionID, argument: String?)
        /// The key after a first key completed none: it goes on to the
        /// focused view, but runs no shortcut.
        case mismatch
        /// The key after the leader completed none: consume it.
        case dismissed
    }

    private(set) var pending: (prefix: Shortcut, window: ObjectIdentifier, focus: FocusState.Resolved?)?

    var isPending: Bool { pending != nil }

    /// The leader while it waits for its second key (the which-key overlay
    /// shows then), else nil.
    var leaderPrefix: Shortcut? {
        guard let prefix = pending?.prefix, prefix == LeaderLayer.prefix else { return nil }
        return prefix
    }

    /// `canArm` says whether the focus lets a chord start (not a text input,
    /// not browser focus mode, no marked text; `KeyRouter.canArm`); asked
    /// only for a first key. `focus` is the window's focus, kept with an
    /// armed chord for ``focusDidChange(to:in:)``.
    mutating func step(_ event: NSEvent, window: ObjectIdentifier, registry: ActionRegistry,
                       focus: FocusState.Resolved? = nil, canArm: () -> Bool) -> Step {
        // A held Cmd-J repeats: the leader stays armed, and a repeat never arms it.
        if event.isARepeat, KeyRouter.isChord(event.modifierFlags), LeaderLayer.prefix.matches(event) {
            return pending?.prefix == LeaderLayer.prefix && pending?.window == window ? .armed : .pass
        }
        if let pending {
            self.pending = nil
            if pending.window == window {
                guard let resolved = registry.resolveChord(after: pending.prefix, event: event) else {
                    return pending.prefix == LeaderLayer.prefix ? .dismissed : .mismatch
                }
                return .run(resolved.id, argument: resolved.argument)
            }
        }
        guard KeyRouter.isChord(event.modifierFlags),
              let prefix = LeaderLayer(registry: registry).chordPrefix(for: event),
              canArm() else { return .pass }
        pending = (prefix, window, focus)
        return .armed
    }

    /// Focus in `window` settled on `focus`: a chord armed there in another
    /// focus ends (a click, Cmd-Tab back, a pane closing), so the next key
    /// reaches the view. Returns whether it ended one.
    mutating func focusDidChange(to focus: FocusState.Resolved, in window: ObjectIdentifier) -> Bool {
        guard let pending, pending.window == window, pending.focus != focus else { return false }
        self.pending = nil
        return true
    }

    mutating func cancel() {
        pending = nil
    }
}
