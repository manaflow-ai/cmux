public import CmuxNextSettings

/// The settings owner (`SettingsController`): schema keys are written only
/// through it, so the socket applies the same validation and managed-key
/// guard as the Settings window and the palette (plans/cmux-next/settings-surfaces.md).
@MainActor public protocol ControlSettingsWriter: AnyObject, Sendable {
    /// Writes one schema setting; nil removes it. Throws `SettingRefused`
    /// or `SettingManaged`.
    func setSetting(at path: [String], to value: JSONValue?) async throws
    /// The managed key a write at `path` would change, or nil.
    func managedKey(forPath path: [String]) -> (key: String, source: ManagedSource)?
}

extension SettingsController: ControlSettingsWriter {}
