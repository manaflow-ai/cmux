import AppKit
import CmuxNextDesign
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
            // The request may end first (deadline, Ctrl-C): then the sheet goes, answered no.
            guard !Task.isCancelled else { return false }
            let shown = ShownDialog()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    shown.id = CmuxDialogCenter.shared.present(DestructiveConfirmation.spec(prompt), in: .window(window)) {
                        continuation.resume(returning: $0.button == DestructiveConfirmation.confirmID)
                    }
                }
            } onCancel: {
                Task { @MainActor in if let id = shown.id { _ = CmuxDialogCenter.shared.dismiss(id) } }
            }
        }
    }

    /// The sheet's dialog id, for a dismissal when the request ends first.
    @MainActor final class ShownDialog: Sendable {
        var id: Int?
    }

    static func defaultValue(_ key: String) -> JSONValue {
        SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: key))?.defaultValue ?? .null
    }
}
