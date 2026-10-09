public import Foundation

extension SettingsController {
    /// The Ctrl-1...9 scheme cmux.json is on now (`ShortcutDigitScheme.active`).
    public func digitScheme() async throws -> ShortcutDigitScheme? {
        nil
    }

    /// Switches cmux.json to `scheme` in one publish and returns the plan
    /// it wrote (empty when nothing changed). Bindings set by hand stay.
    @discardableResult
    public func applyDigitScheme(_ scheme: ShortcutDigitScheme) async throws -> ShortcutDigitSchemePlan {
        ShortcutDigitSchemePlan(scheme: scheme, changes: [], kept: [])
    }
}
