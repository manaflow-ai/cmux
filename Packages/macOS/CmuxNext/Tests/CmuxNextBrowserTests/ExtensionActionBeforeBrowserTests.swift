import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBrowser

/// A toolbar click right after launch can reach a tab whose Chromium browser
/// is still being created (AdGuard's first popup in the store suite). The
/// click must run once the browser exists, not vanish.
@MainActor @Suite struct ExtensionActionBeforeBrowserTests {
    private func makeTab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "ext-early"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    @Test func clickBeforeTheBrowserWaitsForIt() {
        let tab = makeTab()
        tab.runExtensionAction("abc", anchor: CGRect(x: 10, y: 0, width: 24, height: 24))
        #expect(tab.pendingExtensionAction?.id == "abc")
        tab.attach(browser: 41)
        #expect(tab.pendingExtensionAction == nil)
    }
}
