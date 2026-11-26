import AppKit

/// Presents the privacy decision in the window that requested incoming discoverability.
@MainActor
struct DeviceDiscoverabilityConfirmation {
    func confirm(in window: NSWindow?) async -> Bool {
        // A request without a presenting window cannot obtain consent.
        guard let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "devices.incoming.confirm.title",
            defaultValue: "Make this Mac discoverable?"
        )
        alert.informativeText = String(
            localized: "devices.incoming.confirm.message",
            defaultValue: "Other Macs signed in to your cmux account may discover this Mac and connect to its workspaces. Do you want to continue?"
        )
        alert.addButton(withTitle: String(
            localized: "devices.incoming.confirm.enable", defaultValue: "Make Discoverable"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
