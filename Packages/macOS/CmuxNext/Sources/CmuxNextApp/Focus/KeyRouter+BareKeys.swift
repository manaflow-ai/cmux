import AppKit
import CmuxNextActions
import CmuxNextTerminal

// Bare keys (no Command, Control or Option: j, k, G, /, g g) in pages that
// own them (R59 with hq-48, K1): the diff viewer's vim keys and a user's
// bare sequences in a read-only markdown page run cmux bindings only while
// such a context holds (`ActionContext.bareKeyOwners`) and no text field in
// the page has the keyboard (`BareKeys`). Everywhere else a bare key is
// typing and never reaches the binding table.
extension KeyRouter {
    /// No Command, Control or Option (Shift is part of the key: G, ?).
    nonisolated static func isBareKey(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.isDisjoint(with: [.command, .control, .option])
    }

    /// A bare key-down in a cmux window: when the focused page owns bare
    /// keys, the first key of a sequence (`g g`, `] f`) arms the chord
    /// tracker and a single key runs its binding; any other key goes on to
    /// the page unchanged. Returns whether the key was consumed.
    func routesBareKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard Self.isBareKey(event.modifierFlags) else { return false }
        // Typing into a terminal, a text view or an omnibar is never a bare-key binding: it pays no
        // window lookup and no facts (every key-down runs this; typing-frame-bench.py).
        guard let window, !(window.firstResponder is TerminalSurfaceView) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        // Only a page whose context bits include ``ActionContext/bareKeyOwners`` owns bare keys.
        guard let page = focusedPage(in: controller)?.descriptor.id, Self.pageMayOwnBareKeys(page) else { return false }
        let facts = facts(in: window, controller: controller)
        if Self.belongsToInputMethod(event, facts: facts) { return false }
        let context = keyContext(for: controller.focus.state, facts: facts)
        // The focused page owns bare keys now (`KeyContext.ownsBareKeys`): an owning context, and
        // no text field (native or in the page) has the keyboard.
        guard context.ownsBareKeys else { return false }
        return dispatchBare(event, in: window, controller: controller, context: context, facts: facts)
    }
}
