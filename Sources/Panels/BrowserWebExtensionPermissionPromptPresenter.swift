import AppKit
import CmuxBrowser

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
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        return response == .alertFirstButtonReturn ? .grant : .deny
    }
}
