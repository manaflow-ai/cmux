import AppKit
import CmuxNextActions

// A config script's key mode that is on (`ScriptKeyModes`): its own keys run
// before every other path but the recorder, popups and hints, in any focus
// but a text field (a rename sheet, the address bar keep typing).
extension KeyRouter {
    /// Runs `event` in the active key mode. Returns whether it was consumed.
    func routesScriptKeyMode(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let modes = services?.scriptConfig.modes, let mode = modes.active else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, let window, kind == .content else { return false }
        let facts = facts(in: window, controller: controller)
        if Self.belongsToInputMethod(event, facts: facts) { return false }
        let context = keyContext(for: controller.focus.state, facts: facts)
        guard context[KeyContext.textInputFocus] != .bool(true) else { return false }
        if let binding = modes.binding(for: ActionRegistry.shortcuts(for: event), in: context) {
            cancelChord()
            decided.add(event)
            run(Candidate(id: binding.command, tier: registry.keyTier(for: binding.command), source: .registry(argument: binding.argument),
                          arguments: binding.arguments), context: context, window: controller.state.id)
            trace?("key mode \(mode): \(binding.command.rawValue)")
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if flags.isEmpty, event.keyCode == 53 {
            modes.exit()
            trace?("key mode \(mode): Escape ends it")
            return true
        }
        // An exclusive mode swallows typing; Command, Control and Option keys go on.
        return modes.isExclusive && Self.isBareKey(event.modifierFlags)
    }
}
