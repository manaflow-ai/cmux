import AppKit

extension Workspace {
    /// A failed write leaves the local pane where the user put it and preserves the
    /// confirmed daemon coordinates. Surface the divergence so it is never invisible.
    func presentCloudPlacementFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "cloudPane.layoutSyncFailed.title",
            defaultValue: "Couldn’t update the machine workspace"
        )
        alert.informativeText = String(
            localized: "cloudPane.layoutSyncFailed.detail",
            defaultValue: "Your local pane change was kept, but the machine layout could not be synchronized. Reopen the machine workspace to see its current layout."
        ) + "\n\n" + CloudMachineLink.errorText(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK"))
        CloudErrorCopy.install(in: alert, text: "\(alert.messageText)\n\(alert.informativeText)")
        alert.runModal()
    }
}
