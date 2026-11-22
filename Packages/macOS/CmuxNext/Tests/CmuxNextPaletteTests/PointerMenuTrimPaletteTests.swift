import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// Menu trimming preserves the canonical command's vocabulary and search result.
@MainActor @Suite(.paletteRanker)
struct PointerMenuTrimPaletteTests {
    @Test func everyTrimmedPaneActionResolvesFromTheLivePalette() async throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.hide() }
        palette.show(.commands)
        await palette.model.settle()

        for id: ActionID in [
            "newPaneAutoLayout", "triggerFlash", "palette.swapWithSession", "toggleCanvasLayout", "palette.newSimulatorPane",
            "remote.openTerminalHere", "column.moveLeft", "column.moveRight", "column.center", "column.widthOneThird",
            "column.widthHalf", "column.widthTwoThirds", "column.widthFull", "column.dock", "column.undock", "column.float",
            "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
        ] {
            let descriptor = try #require(registry.descriptor(for: id))
            palette.model.send(.setQuery(descriptor.title))
            await palette.model.settle()
            #expect(palette.model.rows.contains { $0.item.actionID == id }, "palette search lost \(id) / \(descriptor.title)")
        }
    }

    @Test func everyTrimmedCommandResolvesFromItsPaletteTitle() throws {
        let ids: [ActionID] = [
            "terminal.keep", "terminal.setTheme", "terminal.clearTheme", "palette.toggleTabUnread",
            "palette.toggleFullWidthTab", "tab.muteOtherAudio", "agentChat.toggleNotificationMute", "tab.showResources",
            "hibernateTab", "wakeTab", "neverHibernateSite", "cloudMove", "cloudBringBack",
            "palette.copyIdentifiers", "browser.resetPinnedTab", "tab.screenshot",
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
