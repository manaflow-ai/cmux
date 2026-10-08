import AppKit
import CmuxNextActions

/// Chords of up to four keys (`["ctrl+b", "c"]` in cmux.json, longer
/// sequences in keybindings.json) for the key router: the first key arms a
/// chord in its window, each key that leads to a longer entry keeps it
/// armed, and the key that completes an entry runs it. As in the old app
/// there is no timeout, and a key in another window ends it. When a key
/// both completes an entry and leads to a longer one, the longer one wins
/// (the chord stays armed), as at the first key.
///
/// The which-key overlay lists the next keys of every armed prefix
/// (``armedKeys``). Escape cancels a chord at any depth and reaches no
/// view. The Cmd-J leader (`LeaderLayer`) is a chord prefix that arms
/// whenever some binding sits under it, even one that cannot run in this
/// focus, so its overlay can say what Cmd-J offers; any key after it that
/// completes nothing (an unbound key, Cmd-J again) is dismissed too, so a
/// stray letter never types into the terminal. After another prefix such a
/// key ends the chord and goes on to the focused view. Holding the last
/// key keeps the chord armed (key repeats are ignored, and a repeat never
/// arms), and a focus change in its window ends it (`focusDidChange(to:in:)`).
struct ChordTracker {
    enum Step: Equatable {
        /// Not a chord key: route the event as usual.
        case pass
        /// A key that starts or extends a chord: consume it and wait.
        case armed
        /// The key completed a chord: run its action.
        case run(ActionID, argument: String?, arguments: [String: ActionValue] = [:])
        /// The key after a prefix completed none: it goes on to the
        /// focused view, but runs no shortcut.
        case mismatch
        /// Escape, or a key after the leader that completed none: consume it.
        case dismissed
    }

    /// What a key after an armed prefix does.
    enum Next {
        /// It completes an entry.
        case run(ActionID, argument: String?, arguments: [String: ActionValue])
        /// It leads to a longer entry: the chord stays armed with it.
        case extend(Shortcut)
        case none
    }

    private(set) var pending: (keys: [Shortcut], window: ObjectIdentifier, focus: FocusState.Resolved?)?

    var isPending: Bool { pending != nil }

    /// The keys of the armed chord (the which-key overlay lists what
    /// follows them), else nil.
    var armedKeys: [Shortcut]? { pending?.keys }

    /// The leader while it waits for its second key, else nil.
    var leaderPrefix: Shortcut? {
        pending?.keys == [LeaderLayer.prefix] ? LeaderLayer.prefix : nil
    }

    /// The registry's binding table with its process-wide context (tests);
    /// the key router passes the key window's context instead.
    mutating func step(_ event: NSEvent, window: ObjectIdentifier, registry: ActionRegistry,
                       focus: FocusState.Resolved? = nil, canArm: () -> Bool) -> Step {
        let bindings = RegistryKeyBindings(registry)
        let context = KeyContext(bits: registry.context)
        return step(event, window: window, focus: focus, table: bindings.table, context: context,
                    isRunnable: { bindings.canPerform($0, in: context.bits) }, canArm: canArm)
    }

    /// Steps with `table` resolved in `context` (the key window's context
    /// keys; `KeyBindingTable.step(after:readings:in:isRunnable:)` holds the
    /// shared sequence rules). `canArm` says whether the focus lets a chord
    /// start (not a text input, not browser focus mode, no marked text;
    /// `KeyRouter.canArm`); asked only for a first key. `focus` is the
    /// window's focus, kept with an armed chord for ``focusDidChange(to:in:)``.
    mutating func step(_ event: NSEvent, window: ObjectIdentifier, focus: FocusState.Resolved? = nil, table: KeyBindingTable,
                       context: KeyContext, isRunnable: (ActionID) -> Bool, canArm: () -> Bool) -> Step {
        func tableStep(_ keys: [Shortcut], _ event: NSEvent) -> KeyBindingTable.SequenceStep {
            table.step(after: keys, readings: ActionRegistry.shortcuts(for: event), in: context, isRunnable: isRunnable)
        }
        return step(event, window: window, focus: focus, first: { event in
            // A first key only arms here; a single key runs through the dispatcher's tier check.
            if case .extend(let key) = tableStep([], event) { return key }
            return nil
        }, next: { keys, event in
            switch tableStep(keys, event) {
            case .run(let winner): .run(winner.command, argument: winner.argument, arguments: winner.arguments)
            case .extend(let key): .extend(key)
            case .none: .none
            }
        }, canArm: canArm)
    }

    /// `first` gives the first key of a chord a key-down arms (or nil);
    /// `next` says what a key-down does after the armed keys.
    mutating func step(_ event: NSEvent, window: ObjectIdentifier, focus: FocusState.Resolved? = nil,
                       first: (NSEvent) -> Shortcut?, next: ([Shortcut], NSEvent) -> Next, canArm: () -> Bool) -> Step {
        if event.isARepeat {
            // A held key repeats: the chord it armed stays armed, and a repeat never arms one.
            guard let pending else { return .pass }
            if pending.window == window, let last = pending.keys.last, ActionRegistry.shortcuts(for: event).contains(last) { return .armed }
        }
        if let pending {
            self.pending = nil
            if pending.window == window {
                guard event.type == .keyDown else { return .mismatch }
                if event.keyCode == Self.escapeKeyCode { return .dismissed }
                switch next(pending.keys, event) {
                case .run(let id, let argument, let arguments):
                    return .run(id, argument: argument, arguments: arguments)
                case .extend(let key):
                    self.pending = (pending.keys + [key], window, pending.focus)
                    return .armed
                case .none:
                    return pending.keys.first == LeaderLayer.prefix ? .dismissed : .mismatch
                }
            }
        }
        guard KeyRouter.isChord(event.modifierFlags), let key = first(event), canArm() else { return .pass }
        self.pending = ([key], window, focus)
        return .armed
    }

    static let escapeKeyCode: UInt16 = 53

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
