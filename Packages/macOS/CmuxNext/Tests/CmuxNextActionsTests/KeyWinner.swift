import CmuxNextActions

/// One key resolved the way the key router resolves it: the binding
/// table's winner in the registry's context (KeyRouter.resolve).
extension ActionRegistry {
    func keyWinner(_ shortcut: Shortcut) -> KeyBinding? {
        let bindings = RegistryKeyBindings(self)
        let bits = context
        return bindings.table.resolve([shortcut], in: KeyContext(bits: bits), isRunnable: { bindings.canPerform($0, in: bits) }).winner
    }

    /// Runs the key's winner as KeyRouter does. Returns whether it ran.
    @discardableResult
    func performKey(_ shortcut: Shortcut) -> Bool {
        guard let winner = keyWinner(shortcut) else { return false }
        return RegistryKeyBindings(self).run(winner, keyContext: context)
    }
}
