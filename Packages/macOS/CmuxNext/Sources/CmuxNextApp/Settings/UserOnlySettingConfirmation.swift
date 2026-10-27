import AppKit
import CmuxNextDesign
import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import CmuxNextWakeups

/// The native sheet for `cmux settings set <user-only key> <value> --confirm` (SECURITY,
/// agent_settable): it names the key and the value and needs a real click or key in the app, so
/// an agent in a terminal cannot answer it. No window to attach to means no, as a declined sheet.
@MainActor
enum UserOnlySettingConfirmation {
    static func install(_ settings: SettingsController, services: AppServices) {
        settings.userOnlyConfirmation = { [weak services] key, value in
            guard let services else { return false }
            let prompt = DestructiveConfirmation.Prompt(
                title: ConfirmationStrings.userOnlySettingTitle(key), body: Self.body(key: key, value: value),
                button: ConfirmationStrings.userOnlySettingButton)
            return await ask(prompt, services: services)
        }
    }

    /// Shows `prompt` on the active window and returns whether the person
    /// confirmed it. Also the sheet of other person-only changes a command
    /// asks for (Set Workspace Localhost).
    static func ask(_ prompt: DestructiveConfirmation.Prompt, services: AppServices) async -> Bool {
        guard let window = services.windows.active?.window else { return false }
        // The request may end first (deadline, Ctrl-C): then the sheet goes, answered no.
        guard !Task.isCancelled else { return false }
        let shown = ShownDialog(), mainWork = services.mainWork
        return await withTaskCancellationHandler {
            // A sheet that goes without an answer (dismissed, dropped) is a no.
            (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
                shown.id = CmuxDialogCenter.shared.present(DestructiveConfirmation.spec(prompt), in: .window(window)) {
                    continuation.resume(returning: $0.button == DestructiveConfirmation.confirmID)
                }
            }) ?? false
        } onCancel: {
            // The request ended (on any thread): the sheet goes in one posted visible task.
            mainWork.postFromAnyThread(.visible, owner: "UserOnlySettingConfirmation.dismiss") {
                if let id = shown.id { _ = CmuxDialogCenter.shared.dismiss(id) }
            }
        }
    }

    /// The sheet's dialog id, for a dismissal when the request ends first.
    @MainActor final class ShownDialog: Sendable {
        var id: Int?
    }

    /// The sheet's text: the key and the value it sets (a reset shows the schema default it returns
    /// to). Turning hang reports on also shows the card's privacy summary, because the approval
    /// records this Mac's consent (``HangReportsController/recordUserWrite(defaults:path:value:)``).
    static func body(key: String, value: JSONValue?) -> String {
        let shown = value ?? Self.defaultValue(key)
        let text = ConfirmationStrings.userOnlySettingBody(key, shown.compactText)
        guard CmuxConfigFile.keyPath(from: key) == HangReportsSetting.path, shown == .bool(true) else { return text }
        return text + "\n\n" + HangReportsStrings.privacySummary
    }

    static func defaultValue(_ key: String) -> JSONValue {
        SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: key))?.defaultValue ?? .null
    }
}
