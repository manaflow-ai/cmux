import CmuxBrowser
import Foundation

/// The agent URL rule for Chromium panels (`String.isRefusedForAgentNavigation`).
///
/// An agent (socket or CLI) never loads, shows or scripts Chromium's own
/// pages (`chrome://settings`, `chrome://password-manager`,
/// `chrome-extension://`, `devtools://`, `view-source:`) or cmux's internal
/// pages in a Chromium panel: they can hand saved passwords to a script or
/// change the profile. The person can still open them by typing them. WebKit
/// panels have no such pages and are unchanged. Same rule as cmux Next.
extension BrowserPanel {
    /// Whether an agent-driven navigation to `rawInput` (or what it resolves
    /// to) must be refused in this panel.
    func refusesAgentNavigation(rawInput: String, resolvedURL: URL?) -> Bool {
        guard enginePage != nil else { return false }
        if rawInput.isRefusedForAgentNavigation { return true }
        return resolvedURL?.isRefusedForAgentNavigation ?? false
    }

    /// Whether an agent may script or send input to the page this panel
    /// shows now. False while a Chromium panel shows a refused page (the
    /// person opened it); automation's eval, keys, cookies and screenshots
    /// check it first.
    var agentMayDriveCurrentPage: Bool {
        guard enginePage != nil, let currentURL else { return true }
        return !currentURL.isRefusedForAgentNavigation
    }

    /// Keeps the engine's agent navigation guard in step with who drives the
    /// page, so a redirect or a back/forward commit into a refused page is
    /// cancelled in the engine while an agent drives it.
    func syncAgentNavigationGuard() {
        enginePage?.setAgentNavigationGuard(browserDialogOwner == .automation)
        // A page automation drives records its protocol events from now on.
        if browserDialogOwner == .automation { startAutomationProtocolTelemetry() }
    }
}
