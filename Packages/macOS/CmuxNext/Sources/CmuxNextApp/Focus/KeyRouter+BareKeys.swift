import AppKit
import CmuxNextActions

// Bare keys (no Command, Control or Option: j, k, G, /) in pages that own
// them (R59 with hq-48): the diff viewer's vim keys run cmux bindings only
// while its context holds (`ActionContext.bareKeyOwners`) and no text field
// in the page has the keyboard. Everywhere else a bare key is typing and
// never reaches the binding table.
extension KeyRouter {
    /// No Command, Control or Option (Shift is part of the key: G, ?).
    nonisolated static func isBareKey(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.isDisjoint(with: [.command, .control, .option])
    }

    /// The focused page owns bare keys now: an owning context, and no text
    /// field (native or in the page) has the keyboard.
    nonisolated static func ownsBareKeys(_ context: KeyContext) -> Bool {
        !context.bits.isDisjoint(with: ActionContext.bareKeyOwners) && context[KeyContext.textInputFocus] != .bool(true)
    }

    /// The binding a bare key runs in `context`, or nil when it is typing.
    func bareKeyWinner(_ event: NSEvent, context: KeyContext) -> KeyBinding? {
        guard Self.isBareKey(event.modifierFlags), Self.ownsBareKeys(context) else { return nil }
        return resolve(event, context: context)
    }

    /// A bare key-down in a cmux window: runs its binding when the focused
    /// page owns bare keys (a sequence like `] f` arms through the chord
    /// tracker). Returns whether the key was consumed.
    func routesBareKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard Self.isBareKey(event.modifierFlags) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, let window, kind == .content else { return false }
        let facts = facts(in: window, controller: controller)
        if Self.belongsToInputMethod(event, facts: facts) { return false }
        let context = keyContext(for: controller.focus.state, facts: facts)
        guard Self.ownsBareKeys(context) else { return false }
        return dispatchBare(event, in: window, controller: controller, context: context, facts: facts)
    }
}
