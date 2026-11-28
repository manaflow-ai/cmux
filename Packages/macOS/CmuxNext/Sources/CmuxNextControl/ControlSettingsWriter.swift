public import CmuxNextSettings

/// The settings owner (`SettingsController`): schema keys are written only
/// through it, so the socket applies the same validation and managed-key
/// guard as the Settings window and the palette (plans/cmux-next/settings-surfaces.md).
@MainActor public protocol ControlSettingsWriter: AnyObject, Sendable {
    /// Writes one schema setting for `writer`; nil removes it. Throws `SettingRefused`,
    /// `SettingManaged` or `SettingUserOnly`.
    func setSetting(at path: [String], to value: JSONValue?, by writer: SettingWriter) async throws
    /// Asks the person at the Mac, on a native sheet, to approve a socket write of a user-only key
    /// (`cmux settings set --confirm`). False when declined or when no sheet can be shown.
    func confirmUserOnlyWrite(key: String, value: JSONValue?) async -> Bool
    /// The managed key a write at `path` would change, or nil.
    func managedKey(forPath path: [String]) -> (key: String, source: ManagedSource)?
}

extension SettingsController: ControlSettingsWriter {
    public func confirmUserOnlyWrite(key: String, value: JSONValue?) async -> Bool {
        await userOnlyConfirmation?(key, value) ?? false
    }
}
