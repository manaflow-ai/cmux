import Foundation

extension SettingsController {
    /// Returns the complete `shortcuts` object for the next keymap export.
    /// The value includes binding, tier and context overrides so an export
    /// can round-trip every keymap concern without touching other settings.
    public func shortcutKeymap() async throws -> JSONValue {
        try await file.value(at: ["shortcuts"]) ?? .object([:])
    }

    /// Imports a keymap object into `shortcuts` in one atomic publish.
    /// Files exported by ``shortcutKeymap()`` contain a top-level
    /// `shortcuts` object; a bare object is accepted as a convenience for
    /// hand-authored keymaps. Existing comments, unknown top-level keys and
    /// settings outside `shortcuts` remain untouched.
    public func importShortcutKeymap(_ value: JSONValue) async throws {
        guard case .object(let root) = value else {
            throw CmuxConfigFile.Failure.invalidPath("keymap must be a JSON object")
        }
        let shortcuts: [String: JSONValue]
        if case .object(let nested)? = root["shortcuts"] {
            shortcuts = nested
        } else if root.keys.contains(where: { ["bindings", "tiers", "when"].contains($0) }) {
            shortcuts = root
        } else {
            shortcuts = ["bindings": .object(root)]
        }
        let edits = shortcuts.map { key, value in
            (path: ["shortcuts", key], value: Optional(value))
        }
        guard !edits.isEmpty else { return }
        try await file.apply(edits)
    }

    /// The edits that switch cmux-next.json to `preset`, from the file as it is.
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
