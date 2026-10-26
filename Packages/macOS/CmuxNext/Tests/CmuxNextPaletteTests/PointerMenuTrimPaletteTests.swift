import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// Menu trimming preserves the canonical command's vocabulary and search result.
@MainActor @Suite(.paletteRanker)
struct PointerMenuTrimPaletteTests {
    @Test func everyTrimmedCommandResolvesFromItsPaletteTitle() throws {
        let ids: [ActionID] = [
            "terminal.keep", "terminal.setTheme", "terminal.clearTheme", "palette.toggleTabUnread",
            "palette.toggleFullWidthTab", "tab.muteOtherAudio", "agentChat.toggleNotificationMute", "tab.showResources",
            "hibernateTab", "wakeTab", "neverHibernateSite", "cloudMove", "cloudBringBack",
            // Send Message… is a context-only alias of the existing Send Message To… command.
            "home.messageTo", "palette.copyIdentifiers", "browser.resetPinnedTab", "tab.screenshot",
            "newPaneAutoLayout", "triggerFlash", "palette.swapWithSession", "toggleCanvasLayout", "palette.newSimulatorPane",
            "remote.openTerminalHere", "column.moveLeft", "column.moveRight", "column.center", "column.widthOneThird",
            "column.widthHalf", "column.widthTwoThirds", "column.widthFull", "column.dock", "column.undock", "column.float",
            "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
            "browserProfile.newTab", "newTab.page", "openDiffViewer", "file.open", "agentPane.searchChats",
        ]
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let items = RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems()
        var index = PaletteSearchIndex(items: items)
        let ranker = PaletteRanker(), frecency = FrecencyStore()
        for id in ids {
            let item = try #require(items.first { $0.actionID == id }, "palette command \(id)")
            let itemIndex = try #require(index.entries.firstIndex { $0.actionID == id.rawValue })
            let sections = ranker.rank(index: &index, version: 1, query: item.title, sectionOrders: [],
                                       frecency: frecency, now: Date(timeIntervalSince1970: 1_000_000), showsRecent: false)
            #expect(sections.flatMap(\.rows).contains { $0.index == itemIndex }, "search lost \(id): \(item.title)")
        }
    }
}
