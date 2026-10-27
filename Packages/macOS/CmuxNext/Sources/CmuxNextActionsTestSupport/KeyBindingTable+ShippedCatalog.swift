package import CmuxNextActions

extension KeyBindingTable {
    /// The binding table the shipped catalog builds, every action bound to a no-op handler.
    @MainActor package static func shippedCatalog() -> KeyBindingTable {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return RegistryKeyBindings(registry).table
    }
}
