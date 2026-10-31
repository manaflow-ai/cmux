import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import Foundation
import CmuxNextHistory

/// Opens `cmux://vault` in a pane (Open Vault as Pane) and makes its pages,
/// each a view over the app's one ``SessionVault``.
@MainActor
final class VaultPageService {
    private let vault: SessionVault
    private let registry: ActionRegistry

    init(vault: SessionVault, registry: ActionRegistry) {
        self.vault = vault
        self.registry = registry
    }

    /// Selects `pane`'s vault tab, else opens one beside its selected tab.
    func open(in pane: PaneController) {
        if let tab = pane.pane.tabs.first(where: { VaultPageAddress.matches($0.url.flatMap(URL.init(string:))) }) {
            pane.select(StripTabID(tab.id))
            return
        }
        pane.newBrowserTab(url: VaultPageAddress.url)
    }

    func makePage(key: String, engine: BrowserEngineKind, profile: BrowserProfileID) -> VaultPageTab {
        VaultPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile,
                     host: VaultHostView(vault: vault, registry: registry))
    }
}
