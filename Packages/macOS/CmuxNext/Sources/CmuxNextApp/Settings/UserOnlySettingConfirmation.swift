import AppKit
import CmuxNextSettings

/// The native sheet for `cmux settings set <user-only key> <value> --confirm` (SECURITY,
/// agent_settable): it names the key and the value and needs a real click or key in the app, so
/// an agent in a terminal cannot answer it. No window to attach to means no, as a declined sheet.
@MainActor
enum UserOnlySettingConfirmation {
    static func install(_ settings: SettingsController, services: AppServices) {
        settings.userOnlyConfirmation = { [weak services] key, value in
            guard let window = services?.windows.active?.window else { return false }
            let prompt = DestructiveConfirmation.Prompt(
                title: ConfirmationStrings.userOnlySettingTitle(key),
                // A reset shows the value it returns to (the schema default).
                body: ConfirmationStrings.userOnlySettingBody(key, (value ?? Self.defaultValue(key)).compactText),
                button: ConfirmationStrings.userOnlySettingButton)
            return await withCheckedContinuation { continuation in
                DestructiveConfirmation.present(prompt, in: window) { continuation.resume(returning: $0) }
            }
        }
    }

    static func defaultValue(_ key: String) -> JSONValue {
        SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: key))?.defaultValue ?? .null
    }
}
