import Testing
@testable import CmuxNextActions

/// A Chromium page menu already lists Back, Forward and Reload; the cmux
/// items appended after it must not repeat them, and must keep the rest
/// (Page Info, DevTools, Extensions).
@Suite struct EngineMenuEntriesTests {
    @Test func noNavigationDuplicatesAfterTheEngineMenu() {
        let ids = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.browserPageAfterEngineMenu)
        for id: ActionID in ["browserBack", "browserForward", "browserReload"] { #expect(!ids.contains(id)) }
        for id: ActionID in ["toggleBrowserDeveloperTools", "browser.extensions.menu", "browser.extensions.manage"] {
            #expect(ids.contains(id))
        }
        if case .separator? = ContextMenuCatalog.shared.browserPageAfterEngineMenu.first { Issue.record("leading separator") }
    }
}
