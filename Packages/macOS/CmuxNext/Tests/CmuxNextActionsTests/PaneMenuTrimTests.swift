import AppKit
@testable import CmuxNextActions
import Testing

/// The pane pointer menu keeps the 30 common actions from the approved menu
/// audit. Specialist geometry and provider rows remain palette actions.
@MainActor
@Suite struct PaneMenuTrimTests {
    private static let retained: Set<ActionID> = [
        "splitRight", "splitDown", "splitLeft", "splitUp", "toggleSplitZoom", "renamePane", "closePane",
        "newColumn", "newRow", "splitBrowserRight", "splitBrowserDown",
        "pane.moveToNewWorkspace", "pane.moveToNewWindow", "swapPaneLeft", "swapPaneRight", "swapPaneUp", "swapPaneDown",
        "pane.closeOthers", "pane.setBackground", "pane.setTint", "pane.clearBackground", "reconnectPane",
        "palette.copyPaneID", "palette.copyPaneLink", "pane.screenshot", "equalizeSplits", "pane.toggleTabBar",
        "agentPaneZoomIn", "agentPaneZoomOut", "agentPaneZoomReset",
    ]

    private static let paletteOnly: Set<ActionID> = [
        "newPaneAutoLayout", "triggerFlash", "palette.swapWithSession", "toggleCanvasLayout", "palette.newSimulatorPane",
        "remote.openTerminalHere", "column.moveLeft", "column.moveRight", "column.center", "column.widthOneThird",
        "column.widthHalf", "column.widthTwoThirds", "column.widthFull", "column.dock", "column.undock", "column.float",
        "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
    ]

    @Test func paneMenuKeepsTheApprovedThirtyAndExemptsTheLongTail() throws {
        let entries = ContextMenuCatalog.shared.entries(for: .pane)
        let shown = Set(ContextMenuCatalog.shared.referencedIDs(entries))
        #expect(shown.count == 30)
        #expect(shown == Self.retained)

        for id in Self.paletteOnly {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "missing (id)")
            #expect(descriptor.isPaletteVisible, "(id) must remain in the command palette")
            #expect(descriptor.surfacePlan.contextMenus.isEmpty, "(id) must leave the pane pointer menu")
            #expect(descriptor.surfacePlan.contextMenuExemption == .minimalMenu, "(id) needs an explicit trim reason")
        }
    }
}
