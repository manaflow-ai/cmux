import AppKit
import CmuxFoundation
import Foundation

@MainActor
struct WorkspaceTemplateErrorPresenter {
    let presentingWindow: NSWindow?

    func present(_ error: Error) {
        let message: String
        if case CmuxTemplateResolutionError.missingVariables(let names) = error {
            let format = String(
                localized: "dialog.workspaceTemplate.missingParameters.message",
                defaultValue: "Missing values for: %@"
            )
            message = String.localizedStringWithFormat(format, names.joined(separator: ", "))
        } else {
            message = String(
                localized: "dialog.workspaceTemplate.failed.message",
                defaultValue: "The workspace template could not be resolved."
            )
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.workspaceTemplate.missingParameters.title",
            defaultValue: "Workspace Parameters Required"
        )
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        if let presentingWindow {
            alert.beginSheetModal(for: presentingWindow)
        } else {
            _ = alert.runModal()
        }
    }
}
