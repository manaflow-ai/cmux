import AppKit

extension AppDelegate {
    func performConfiguredMobileConnectAction(
        context: MainWindowContext,
        preferredWindow: NSWindow?,
        onExecuted: (() -> Void)?
    ) -> Bool {
        guard openMobilePairingPane(
            debugSource: "configured.cmux.mobileConnect",
            tabManager: context.tabManager,
            preferredWindow: resolvedWindow(for: context) ?? preferredWindow
        ) else {
            return false
        }
        onExecuted?()
        return true
    }
}
