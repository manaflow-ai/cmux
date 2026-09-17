import AppKit
import CmuxSettings

/// The Detach / Kill Process / Cancel prompt for closing a cloud terminal pane,
/// with a "Remember my choice" box that writes `app.closeCloudTerminal`.
@MainActor
enum CloudTerminalCloseAlertPresenter {
    struct Result: Equatable, Sendable {
        let decision: CloudTerminalCloseDecision
        let remember: Bool
    }

    /// Presents the prompt as a sheet on the main cmux window (app-modal when no
    /// window can host a sheet) and returns what the person chose.
    static func present(prompt: CloudTerminalClosePrompt, presentingWindow: NSWindow? = nil) -> Result {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: String(localized: "dialog.closeCloudTerminal.detach", defaultValue: "Detach"))
        alert.addButton(withTitle: String(localized: "dialog.closeCloudTerminal.kill", defaultValue: "Kill Process"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        if let detachButton = alert.buttons.first {
            detachButton.keyEquivalent = "\r"
            detachButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = detachButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = detachButton
        }
        if alert.buttons.indices.contains(2) {
            alert.buttons[2].keyEquivalent = "\u{1b}"
        }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(
            localized: "dialog.closeCloudTerminal.remember",
            defaultValue: "Remember my choice (change it in Settings \u{203A} App)"
        )

        let response = alert.runCmuxModal(
            presentingWindow: presentingWindow,
            content: CmuxAlertContent(informativeText: prompt.message)
        )
        let index: Int
        switch response {
        case .alertFirstButtonReturn: index = 0
        case .alertSecondButtonReturn: index = 1
        default: index = 2
        }
        return Result(
            decision: CloudTerminalClosePolicy.decision(forButtonIndex: index),
            remember: alert.suppressionButton?.state == .on
        )
    }

    /// A kill that the machine refused (asleep, link down, terminal gone). The
    /// pane stays open so the person knows the process is still running.
    static func presentKillFailure(terminalName: String, error: Error, presentingWindow: NSWindow? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "dialog.killCloudTerminal.failed.title", defaultValue: "Couldn\u{2019}t kill \u{201C}%@\u{201D}"),
            locale: .current,
            terminalName
        )
        let detail = CloudMachineLink.errorText(error)
        alert.informativeText = detail.isEmpty ? String(describing: error) : detail
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: presentingWindow)
    }
}
