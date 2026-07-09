import AppKit
import Foundation

/// Handling for `cmux://extensions/install` deep links (parsed by
/// `CmuxExtensionInstallURLRequest`); dispatched from the custom-scheme
/// fan-out in `AppDelegate+CmuxSSHURL.swift`.
extension AppDelegate {
    /// `cmux://extensions/install?repo=…` — opens the extension consent
    /// window; nothing installs without the user approving the previewed
    /// commands there (a deep link can never skip consent).
    @discardableResult
    func handleCmuxExtensionInstallURLs(from urls: [URL]) -> Bool {
        var requests: [CmuxExtensionInstallURLRequest] = []
        var parseErrorCount = 0

        for url in urls {
            switch CmuxExtensionInstallURLRequest.parse(url) {
            case .success(.some(let request)):
                requests.append(request)
            case .success(nil):
                break
            case .failure(let error):
#if DEBUG
                cmuxDebugLog("extensionInstallURL.blocked reason=\(error) url=\(url.absoluteString.prefix(160))")
#endif
                parseErrorCount += 1
            }
        }

        let intentCount = requests.count + parseErrorCount
        guard intentCount > 0 else { return false }
        guard intentCount == 1, let request = requests.first else {
            // Malformed or multiple install links: recognized, but never acted
            // on — the consent window is the only path to an install. Tell the
            // user why nothing opened (parity with the SSH/text link alerts).
            showCmuxExtensionInstallURLBlockedAlert()
            return true
        }

        DockExtensionsRuntime.shared.installCoordinator.beginInstall(
            input: request.source,
            ref: request.ref
        )
        return true
    }

    private func showCmuxExtensionInstallURLBlockedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.textURL.blocked.title",
            defaultValue: "cmux Link Blocked"
        )
        alert.informativeText = String(
            localized: "dialog.extensionInstallURL.blocked.message",
            defaultValue: "This extension install link is malformed, so it was ignored. Nothing was installed."
        )
        alert.addButton(withTitle: String(localized: "dialog.textURL.blocked.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
