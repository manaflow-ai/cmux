import AppKit
import Bonsplit
import Foundation

/// Shared entrypoint for every "Upgrade to cmux Pro" surface (sidebar badge,
/// titlebar badge, Settings Account card, command palette, Help menu). Opens
/// the pricing page as a browser split on the right of the current workspace,
/// inside the same window, instead of a separate window or external browser.
enum ProUpgradePresenter {
    @MainActor
    static func present() {
        let url = AuthEnvironment.pricingURL

        // Preferred: a browser split to the right of the focused pane, so the
        // pricing screen sits beside the user's work in the same window.
        if let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
           let sourcePanelId = workspace.focusedPanelId,
           workspace.newBrowserSplit(
               from: sourcePanelId,
               orientation: .horizontal,
               url: url,
               focus: true,
               omnibarVisible: false
           ) != nil {
            return
        }

        // Fallbacks so the entrypoint never silently no-ops: a browser tab in
        // the current window, then the system browser.
        if AppDelegate.shared?.openBrowserAndFocusAddressBar(url: url) != nil {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
