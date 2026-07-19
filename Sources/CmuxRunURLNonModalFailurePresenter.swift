import AppKit
import Foundation

@MainActor
final class CmuxRunURLNonModalFailurePresenter: NSObject {
    private var alert: NSAlert?

    var window: NSWindow? {
        alert?.window
    }

    func show(message: String) {
        if let alert, alert.window.isVisible {
            alert.informativeText = message
            alert.window.orderFrontRegardless()
            NSApp.requestUserAttention(.informationalRequest)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.runURL.failure.title",
            defaultValue: "Command Link Blocked"
        )
        alert.informativeText = message
        let button = alert.addButton(
            withTitle: String(localized: "dialog.runURL.failure.ok", defaultValue: "OK")
        )
        button.target = self
        button.action = #selector(dismiss)
        alert.window.level = .floating
        alert.window.isReleasedWhenClosed = false
        self.alert = alert
        alert.window.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    @objc func dismiss() {
        alert?.window.close()
        alert = nil
    }
}
