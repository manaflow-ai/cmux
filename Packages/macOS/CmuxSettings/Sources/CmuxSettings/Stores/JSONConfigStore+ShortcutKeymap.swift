import Foundation

extension JSONConfigStore {
    /// Writes a keymap preset's plan to `shortcuts.bindings`.
    ///
    /// Each change is one leaf edit, so comments and bindings the plan does
    /// not name survive. Removals run first so a failed write never leaves
    /// two presets' values mixed on the same action.
    ///
    /// - Parameters:
    ///   - plan: The plan from ``ShortcutKeymapPreset/plan(from:defaultShortcutResolver:)``.
    ///   - bindingsID: The dotted id of the bindings object.
    /// - Throws: The first file or parse error; earlier edits stay applied.
    public func applyShortcutKeymap(
        _ plan: ShortcutKeymapPlan,
        bindingsID: String = "shortcuts.bindings"
    ) async throws {
        let ordered = plan.changes.filter { $0.write == nil } + plan.changes.filter { $0.write != nil }
        for change in ordered {
            let key = JSONKey<ShortcutKeymapBinding>(
                id: "\(bindingsID).\(change.action.rawValue)",
                defaultValue: .unbound
            )
            if let binding = change.write {
                try await set(binding, for: key)
            } else {
                try await reset(key)
            }
        }
    }
}
