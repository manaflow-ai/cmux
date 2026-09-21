import AppKit

/// Presents a bounded, localized error when a remote file preview cannot be materialized.
@MainActor
enum FileExplorerRemotePreviewPresentation {
    static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "fileExplorer.preview.failedTitle", defaultValue: "Unable to open remote file")
        alert.informativeText = (error as? FileExplorerError)?.localizedDescription
            ?? String(localized: "fileExplorer.preview.genericFailure", defaultValue: "The remote file could not be downloaded. Reconnect and try again.")
        alert.addButton(withTitle: String(localized: "fileExplorer.preview.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: NSApp.keyWindow)
    }
}
