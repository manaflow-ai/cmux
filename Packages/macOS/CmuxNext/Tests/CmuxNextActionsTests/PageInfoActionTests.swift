import CmuxNextActions
import Testing

/// Page Info controls reach every entrypoint: palette, CLI, the browser page
/// context menu, and a shortcut (default for the bubble, user-set for the
/// rest).
@MainActor
struct PageInfoActionTests {
    private var pageInfoIDs: [ActionID] {
        ActionCatalog.all.map(\.id).filter { $0 == "browser.pageInfo" || $0.rawValue.hasPrefix("browser.pageInfo.") }
    }

    @Test func everyPageInfoActionIsInTheBrowserPageContextMenu() {
        let menu = Set(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .browserPage)))
        // The list comes from the catalog; it only must not be empty (a
        // renamed prefix would otherwise pass the loop below vacuously).
        #expect(!pageInfoIDs.isEmpty)
        for id in pageInfoIDs {
            #expect(menu.contains(id), "\(id) is missing from the browser page context menu")
        }
    }

    @Test func everyPageInfoActionHasPaletteCLIAndShortcutSurfaces() throws {
        for id in pageInfoIDs {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.isPaletteVisible)
            #expect(descriptor.surfaces.contains(.keyboard))
            #expect(descriptor.surfaces.contains(.contextMenu))
            #expect(descriptor.cliName.hasPrefix("browser "))
        }
        #expect(ActionRegistry.standard().shortcutDisplay(for: "browser.pageInfo") == "⌃⌘I")
    }
}
