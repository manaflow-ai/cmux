import AppKit
@testable import CmuxNextActions
import Testing

/// A menu's own facts (`ActionRegistry.impliedContext(for:)`) enable and run its rows: a Files
/// row runs the explorer's actions while a terminal has the keyboard. Facts a call site adds
/// (`makeContextMenu(implied:)`) only show rows: the bookmarks bar shows Bookmark This Page, but
/// with no browser focused the row stays disabled instead of running and refusing.
@MainActor
struct ContextMenuImpliedFactsTests {
    private func row(_ id: ActionID, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { ActionRegistry.menuRun(of: $0)?.id == id }
    }

    @Test func theMenusOwnFactsEnableAndRunItsRows() throws {
        _ = NSApplication.shared // NSMenu.update validates its items only in an app
        let registry = ActionRegistry.standard()
        var runs: [ActionInvocation] = []
        registry.bind("fileExplorerCopyPath", invoke: { runs.append($0) })
        registry.context = []
        let menu = registry.makeContextMenu(for: .fileExplorerRow)
        let copy = try #require(row("fileExplorerCopyPath", in: menu))
        menu.update()
        #expect(copy.isEnabled)
        _ = (copy.target as? NSObject)?.perform(copy.action, with: copy)
        let ranFocused = runs.first?.keyContext?.contains(.fileExplorerFocused) == true
        #expect(ranFocused, "the row ran without the menu's fileExplorerFocused")
    }

    @Test func aCallSitesFactsOnlyShowRows() throws {
        _ = NSApplication.shared // NSMenu.update validates its items only in an app
        let registry = ActionRegistry.standard()
        var runs: [ActionInvocation] = []
        registry.bind("bookmark.addPage", invoke: { runs.append($0) })
        registry.context = []
        let menu = registry.makeContextMenu(for: .bookmarksBar, implied: .browserFocused)
        let add = try #require(row("bookmark.addPage", in: menu), "the bar shows Bookmark This Page")
        menu.update()
        #expect(!add.isEnabled, "Bookmark This Page is enabled with no browser focused")
        _ = (add.target as? NSObject)?.perform(add.action, with: add)
        #expect(runs.isEmpty, "Bookmark This Page ran with no browser focused")
    }
}
