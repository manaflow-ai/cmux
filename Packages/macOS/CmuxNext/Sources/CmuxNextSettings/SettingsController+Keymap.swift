import Foundation

extension SettingsController {
    /// The edits that switch cmux.json to `preset`, from the file as it is.
    public func keymapPlan(_ preset: ShortcutKeymapPreset) async throws -> ShortcutKeymapPlan {
        preset.plan(from: try await shortcutBindings())
    }

    /// Writes `plan` in one publish. A removed override also goes from the
    /// legacy `shortcuts.<id>` form, so the cmux default applies again.
    public func apply(_ plan: ShortcutKeymapPlan) async throws {
        var edits: [(path: [String], value: JSONValue?)] = []
        for change in plan.changes {
            edits.append((["shortcuts", "bindings", change.actionID], change.write))
            if change.write == nil { edits.append((["shortcuts", change.actionID], nil)) }
        }
        try await file.apply(edits)
    }

    /// `shortcuts.bindings` merged over the legacy `shortcuts.<id>` keys, as
    /// `CmuxConfigSnapshot` reads them.
    private func shortcutBindings() async throws -> [String: JSONValue] {
        guard case .object(let section)? = try await file.value(at: ["shortcuts"]) else { return [:] }
        var bindings = section.filter { !CmuxConfigSnapshot.reservedShortcutKeys.contains($0.key) }
        if case .object(let entries)? = section["bindings"] {
            bindings.merge(entries) { _, binding in binding }
        }
        return bindings
    }
}
