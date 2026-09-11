import Foundation

/// The private notification row used to request a Mac browser pane from a VM.
struct CloudBrowserOpenRequest {
    static let notificationTitle = "cmux.open-url"
}

extension CmuxTuiSurfaceProvider {
    /// Consumes a guest URL request and opens it beside the source terminal.
    @MainActor
    func handleCloudBrowserOpenRequest(
        _ row: CloudVMNotificationRow,
        target: CloudNotificationDeliveryTarget
    ) -> Bool {
        guard row.title == CloudBrowserOpenRequest.notificationTitle else { return false }
        guard let terminalID = row.terminalID,
              let url = URL(string: row.body),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let sourcePanelID = target.panelID else {
            return true
        }
        guard catalog.snapshot.resources.contains(where: {
            $0.id == SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        }) else {
            return false
        }

        // Match terminal-link policy: the setting chooses an embedded cmux
        // browser, while a disabled browser opens the user's system browser.
        return TerminalLinkOpenCoordinator(
            deferOperation: { operation in operation() }
        ).open(TerminalLinkOpenRequest(
            rawValue: url.absoluteString,
            sourceWorkspaceId: target.workspaceID,
            sourcePanelId: sourcePanelID,
            workingDirectory: nil,
            focus: false
        ))
    }
}
