import CmuxNextActions
import Foundation

extension SettingsController {
    /// The edits that switch cmux.json to `preset`, from the file as it is.
    public func keymapPlan(_ preset: ShortcutKeymapPreset) async throws -> ShortcutKeymapPlan {
        preset.plan(from: try await shortcutBindings())
    }

    /// The preset cmux.json is on, or nil when it mixes presets.
    public func activeKeymap() async throws -> ShortcutKeymapPreset? {
        ShortcutKeymapPreset.active(in: try await shortcutBindings())
    }

    /// Writes `plan`. A removed override also goes from the legacy
    /// `shortcuts.<id>` form, so the cmux default applies again.
    public func apply(_ plan: ShortcutKeymapPlan) async throws {
        for change in plan.changes {
            if let value = change.write {
                try await file.set(value, at: ["shortcuts", "bindings", change.actionID])
            } else {
                try await resetShortcut(for: ActionID(rawValue: change.actionID))
            }
        }
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
