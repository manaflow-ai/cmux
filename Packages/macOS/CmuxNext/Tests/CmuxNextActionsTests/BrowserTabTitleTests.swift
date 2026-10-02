import CmuxNextActions
import Testing

/// User request 2026-10-01: Chromium is the browser tab; WebKit is more
/// buggy, so New WebKit Tab leaves every menu and stays in the palette,
/// marked experimental.
@MainActor
@Suite struct BrowserTabTitleTests {
    let byID = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })

    @Test func chromiumIsTheNewBrowserTab() throws {
        let chromium = try #require(byID["openBrowser.chromium"])
        #expect(chromium.title == "New Browser Tab")
        #expect(chromium.surfacePlan.contextMenus.contains { $0.context == .newTab })
        #expect(chromium.surfacePlan.contextMenus.contains { $0.context == .tab })
    }

    @Test func webKitIsPaletteOnlyAndExperimental() throws {
        let webkit = try #require(byID["openBrowser.webkit"])
        #expect(webkit.title == "New WebKit Tab (experimental)")
        #expect(webkit.surfacePlan.palette == .offered)
        #expect(webkit.surfacePlan.contextMenus.isEmpty)
        #expect(webkit.surfacePlan.contextMenuExemption == .experimental)
        for context in ActionMenuContext.allCases {
            let ids = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
            #expect(!ids.contains("openBrowser.webkit"), "\(context)")
        }
    }
}
