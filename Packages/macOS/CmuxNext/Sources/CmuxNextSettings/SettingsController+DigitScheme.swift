public import Foundation

extension SettingsController {
    /// The Ctrl-1...9 scheme cmux.json is on now (`ShortcutDigitScheme.active`),
    /// read from the file so a write the watcher has not reloaded counts.
    public func digitScheme() async throws -> ShortcutDigitScheme? {
        ShortcutDigitScheme.active(in: try await shortcutBindings())
    }

    /// Switches cmux.json to `scheme` in one publish and returns the plan
    /// it wrote (empty when nothing changed). Bindings set by hand stay. A
    /// removed override also goes from the legacy `shortcuts.<id>` form, so
    /// the catalog default applies again.
    @discardableResult
    public func applyDigitScheme(_ scheme: ShortcutDigitScheme) async throws -> ShortcutDigitSchemePlan {
        let plan = scheme.plan(from: try await shortcutBindings())
        guard !plan.isEmpty else { return plan }
        var edits: [(path: [String], value: JSONValue?)] = []
        for change in plan.changes {
            edits.append((["shortcuts", "bindings", change.actionID], change.write))
            if change.write == nil { edits.append((["shortcuts", change.actionID], nil)) }
        }
        try await file.apply(edits)
        return plan
    }
}
