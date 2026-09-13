import AppKit

extension Workspace {
    /// Report a refused name without entering a process-modal loop or activating
    /// another window. Accepted graph names remain unchanged behind the sheet.
    func presentCloudRenameFailure(_ error: Error) {
        guard let window = owningTabManager?.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "cloudPane.layoutSyncFailed.title", defaultValue: "Couldn’t update the machine workspace")
        alert.informativeText = CloudMachineLink.errorText(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK"))
        CloudErrorCopy.install(in: alert, text: "\(alert.messageText)\n\(alert.informativeText)")
        alert.beginSheetModal(for: window)
    }
}
