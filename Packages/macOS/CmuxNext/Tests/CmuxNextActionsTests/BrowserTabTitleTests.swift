import AppKit
import CmuxNextActions
import Testing

/// Lawrence (2026-10-01): Chromium and WebKit are both first class; Chromium
/// is the default. The palette has one New Browser Tab row (`openBrowser`,
/// Cmd-Shift-L, the default engine). WebKit is reachable only from the
/// palette, the CLI and MCP: New WebKit Tab and Reopen in WebKit are in no
/// right-click menu.
@MainActor
@Suite struct BrowserTabTitleTests {
    let catalog = ActionCatalog.all
    var byID: [ActionID: ActionDescriptor] { Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) }) }

    @Test func thePaletteHasOneNewBrowserTabRow() throws {
        let rows = catalog.filter { $0.isPaletteVisible && $0.title == "New Browser Tab" }.map(\.id)
        #expect(rows == ["openBrowser"])
        let chromium = try #require(byID["openBrowser.chromium"])
        #expect(chromium.title == "New Browser Tab")
        #expect(chromium.surfacePlan.palette == .exempt(.duplicateOfDefault))
        #expect(chromium.surfacePlan.cli == .offered)
        #expect(chromium.surfacePlan.mcp == .offered)
        #expect(chromium.surfacePlan.contextMenus.contains { $0.context == .newTab })
    }

    @Test func webKitIsOnlyInThePaletteTheCLIAndMCP() throws {
        for id: ActionID in ["openBrowser.webkit", "browser.openInWebKit"] {
            let webkit = try #require(byID[id])
            #expect(webkit.surfacePlan.palette == .offered, "\(id)")
            #expect(webkit.surfacePlan.cli == .offered, "\(id)")
            #expect(webkit.surfacePlan.mcp == .offered, "\(id)")
            #expect(webkit.surfacePlan.contextMenus.isEmpty, "\(id)")
            #expect(webkit.surfacePlan.contextMenuExemption == .secondaryEngine, "\(id)")
            #expect(webkit.mainMenu == nil, "\(id)")
            for context in ActionMenuContext.allCases {
                let ids = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
                #expect(!ids.contains(id), "\(id) in \(context)")
            }
        }
        let chrome = try #require(byID["browser.openInChromium"])
        #expect(chrome.surfacePlan.contextMenus.contains { $0.context == .tab })
    }

    /// Cmd-Ctrl-D is New Column, so Cmd-Ctrl-Shift-D is New Row
    /// (plans/cmux-next/rows.md); Open Diff Viewer moved to Cmd-Ctrl-Shift-G.
    @Test func cmdCtrlShiftDIsReservedForNewRow() throws {
        let reserved = Shortcut("d", modifiers: [.control, .shift, .command])
        let holders = catalog.filter { $0.defaultShortcut == reserved }.map(\.id)
        #expect(holders.allSatisfy { $0 == "newRow" }, "\(holders)")
        let diff = try #require(byID["openDiffViewer"])
        #expect(diff.defaultShortcut == Shortcut("g", modifiers: [.control, .shift, .command]))
        #expect(catalog.filter { $0.defaultShortcut == diff.defaultShortcut }.map(\.id) == ["openDiffViewer"])
    }
}
