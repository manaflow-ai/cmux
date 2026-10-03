import AppKit
import CmuxNextActions

/// Two-key shortcuts (`["ctrl+b", "c"]` in cmux.json) for the key router:
/// the first key arms a chord in its window, and the next key-down there
/// completes it or ends it. As in the old app there is no timeout, and a
/// key in another window ends it.
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

    private(set) var pending: (prefix: Shortcut, window: ObjectIdentifier)?

    var isPending: Bool { pending != nil }

    /// The leader while it waits for its second key. Stub.
    var leaderPrefix: Shortcut? { nil }

    /// `canArm` says whether the focus lets a chord start (not a text input,
    /// not browser focus mode, no marked text); asked only for a first key.
    mutating func step(_ event: NSEvent, window: ObjectIdentifier, registry: ActionRegistry,
                       focus: FocusState.Resolved? = nil, canArm: () -> Bool) -> Step {
        if let pending {
            self.pending = nil
            if pending.window == window {
                guard let resolved = registry.resolveChord(after: pending.prefix, event: event) else { return .mismatch }
                return .run(resolved.id, argument: resolved.argument)
            }
        }
        guard KeyRouter.isChord(event.modifierFlags), let prefix = registry.chordPrefix(for: event), canArm() else { return .pass }
        pending = (prefix, window)
        return .armed
    }

    /// Focus in `window` settled on `focus`. Stub: ends nothing.
    mutating func focusDidChange(to focus: FocusState.Resolved, in window: ObjectIdentifier) -> Bool { false }

    mutating func cancel() {
        pending = nil
    }
}
