import AppKit
import WebKit

@MainActor
protocol BrowserWebExtensionHosting: AnyObject {
    var isInitialReconciliationComplete: Bool { get }
    func waitForInitialReconciliation() async
    func attach(to configuration: WKWebViewConfiguration)
    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration?
    func register(panel: BrowserPanel)
    func unregister(panelID: UUID)
    func noteWindowChanged(panelID: UUID, nativeWindow: NSWindow?)
    func noteWindowClosed(_ nativeWindow: NSWindow) -> UUID?
    func discardWindowOwnership(panelIDs: [UUID])
    func noteUserOwnedPanelAdded(nativeWindow: NSWindow?, alongsidePanelIDs: [UUID])
    func isPanelActiveInWindow(_ panelID: UUID) -> Bool
    func noteActivated(panelID: UUID)
    func noteTabMetadataChanged(panelID: UUID)
    func performCommand(for event: NSEvent) -> Bool
}

extension BrowserWebExtensionHosting {
    var isInitialReconciliationComplete: Bool { true }

    func waitForInitialReconciliation() async {}

    func noteWindowChanged(panelID: UUID) {
        noteWindowChanged(panelID: panelID, nativeWindow: nil)
    }

    func noteWindowChanged(panelID _: UUID, nativeWindow _: NSWindow?) {}

    func noteWindowClosed(_: NSWindow) -> UUID? { nil }

    func discardWindowOwnership(panelIDs _: [UUID]) {}

    func noteUserOwnedPanelAdded(nativeWindow _: NSWindow?, alongsidePanelIDs _: [UUID]) {}

    func isPanelActiveInWindow(_: UUID) -> Bool { false }
}
