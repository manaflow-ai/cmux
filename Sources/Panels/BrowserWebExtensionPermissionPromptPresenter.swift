import AppKit
import CmuxBrowser

@MainActor
private final class BrowserWebExtensionPermissionSheetSession {
    private let alert: NSAlert
    private let window: NSWindow
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    private var isFinished = false

    init(alert: NSAlert, window: NSWindow) {
        self.alert = alert
        self.window = window
    }

    func response() async -> NSApplication.ModalResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .alertSecondButtonReturn)
                    return
                }
                self.continuation = continuation
                alert.beginSheetModal(for: window) { [weak self] response in
                    self?.finish(response)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func cancel() {
        guard !isFinished else { return }
        if alert.window.sheetParent != nil {
            window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        finish(.alertSecondButtonReturn)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard !isFinished else { return }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: response)
    }
}

@MainActor
struct BrowserWebExtensionPermissionPromptPresenter {
    func decision(
        for request: BrowserWebExtensionPermissionRequest,
        window: NSWindow?
    ) async -> BrowserWebExtensionPermissionDecision {
        guard let window else { return .deny }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String.localizedStringWithFormat(
            String(
                localized: "browser.extensions.permission.title",
                defaultValue: "Allow %@ additional access?"
            ),
            request.extensionName
        )
        let details = request.permissions + request.hosts
        alert.informativeText = details.isEmpty
            ? String(
                localized: "browser.extensions.permission.detail.generic",
                defaultValue: "The extension requested additional access."
            )
            : details.joined(separator: "\n")
        alert.addButton(withTitle: String(
            localized: "browser.extensions.permission.allow",
            defaultValue: "Allow"
        ))
        alert.addButton(withTitle: String(
            localized: "browser.extensions.permission.deny",
            defaultValue: "Deny"
        ))
        let response = await BrowserWebExtensionPermissionSheetSession(
            alert: alert,
            window: window
        ).response()
        return response == .alertFirstButtonReturn ? .grant : .deny
    }
}
