import AppKit

/// User-facing entry points for attaching a remote tmux server (the beta
/// `remoteTmux` feature). The command palette and the menu bar item both funnel
/// through ``promptAttachRemoteTmuxHost(preferredWindow:)`` so the prompt and
/// attach flow live in one place.
extension AppDelegate {
    /// Prompts for an SSH destination and, on confirm, opens a new cmux window
    /// mirroring that server's tmux sessions 1:1 (see
    /// ``RemoteTmuxController/mirrorHostInNewWindow(host:)``).
    ///
    /// No-ops (with a beep) when the `remoteTmux` beta flag is off.
    @MainActor
    func promptAttachRemoteTmuxHost(preferredWindow: NSWindow? = nil) {
        guard RemoteTmuxController.isEnabled else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "remoteTmux.attach.title",
            defaultValue: "Attach Remote tmux"
        )
        alert.informativeText = String(
            localized: "remoteTmux.attach.message",
            defaultValue: "Enter an SSH destination (a ~/.ssh/config alias or user@host). cmux opens a new window mirroring that server's tmux sessions."
        )
        let input = NSTextField(string: "")
        input.placeholderString = String(
            localized: "remoteTmux.attach.placeholder",
            defaultValue: "user@host or ssh alias"
        )
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: String(
            localized: "remoteTmux.attach.confirm",
            defaultValue: "Attach"
        ))
        alert.addButton(withTitle: String(localized: "alert.cancel", defaultValue: "Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        // Reject a dash-prefixed destination — it is never a valid SSH
        // alias/user@host and refusing it guards against ssh option injection.
        guard !destination.hasPrefix("-") else {
            presentRemoteTmuxAttachError(
                destination: destination,
                detail: String(
                    localized: "remoteTmux.attach.invalidDestination",
                    defaultValue: "An SSH destination cannot start with “-”."
                )
            )
            return
        }

        let host = RemoteTmuxHost(destination: destination)
        Task { @MainActor in
            do {
                _ = try await self.remoteTmuxController.mirrorHostInNewWindow(host: host)
            } catch {
                self.presentRemoteTmuxAttachError(
                    destination: destination,
                    detail: String(describing: error)
                )
            }
        }
    }

    /// Shows a warning alert when attaching to a remote tmux server fails.
    @MainActor
    private func presentRemoteTmuxAttachError(destination: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "remoteTmux.attach.failed.title",
            defaultValue: "Couldn’t attach to remote tmux"
        )
        alert.informativeText = "\(destination): \(detail)"
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
