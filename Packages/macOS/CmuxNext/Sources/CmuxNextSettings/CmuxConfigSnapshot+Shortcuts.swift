nonisolated extension CmuxConfigSnapshot {
    /// Keys under `shortcuts` that are settings, not action IDs.
    static let reservedShortcutKeys: Set<String> = ["bindings", "tiers", "when", "showModifierHoldHints"]
}
