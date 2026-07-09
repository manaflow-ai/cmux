import AppKit
import WebKit

@MainActor
protocol BrowserWebExtensionHosting: AnyObject {
    func attach(to configuration: WKWebViewConfiguration)
    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration?
    func register(panel: BrowserPanel)
    func unregister(panelID: UUID)
    func noteActivated(panelID: UUID)
    func noteTabMetadataChanged(panelID: UUID)
    func performCommand(for event: NSEvent) -> Bool
}
