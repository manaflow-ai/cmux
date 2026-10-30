import AppKit
@testable import CmuxNextActions
import Testing

@MainActor
struct PointerMenuTrimTests {
    private static let tabTrimmed: Set<ActionID> = [
        "terminal.keep", "terminal.setTheme", "terminal.clearTheme", "palette.toggleTabUnread",
        "palette.toggleFullWidthTab", "tab.muteOtherAudio", "agentChat.toggleNotificationMute",
        "hibernateTab", "wakeTab", "neverHibernateSite", "cloudMove", "cloudBringBack",
        "browser.resetPinnedTab", "tab.screenshot",
    ]

    private static let paneTrimmed: Set<ActionID> = [
        "newPaneAutoLayout", "triggerFlash", "palette.swapWithSession", "toggleCanvasLayout", "palette.newSimulatorPane",
        "remote.openTerminalHere", "column.moveLeft", "column.moveRight", "column.center", "column.widthOneThird",
        "column.widthHalf", "column.widthTwoThirds", "column.widthFull", "column.dock", "column.undock", "column.float",
        "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
    ]

    @Test func theTabMenuDropsSixteenLongTailRows() throws {
        let catalog = ContextMenuCatalog.shared
        let shown = Set(catalog.referencedIDs(catalog.entries(for: .tab)))
        #expect(shown.isDisjoint(with: Self.tabTrimmed))
        // Context-dependent rows remain declared for targets that support them.
        for id: ActionID in ["tab.pictureInPicture", "agentChat.copyIdentifier", "disconnectRemoteTab", "home.messageAbout"] {
            #expect(shown.contains(id), "conditional tab action \(id)")
        }
        for id in Self.tabTrimmed {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(!descriptor.surfacePlan.contextMenus.contains { $0.context == .tab })
            if descriptor.surfacePlan.contextMenus.isEmpty {
                #expect(descriptor.surfacePlan.contextMenuExemption == .minimalMenu, "\(id)")
            }
        }
        // Shared commands retain their other pointer surfaces.
        for (context, id): (ActionMenuContext, ActionID) in [(.workspaceRow, "home.messageAbout"),
                                                            (.agentChat, "home.messageAbout"), (.agentChat, "cloudMove"), (.agentChat, "cloudBringBack")] {
            #expect(catalog.referencedIDs(catalog.entries(for: context)).contains(id))
        }
    }

    @Test func thePaneMenuKeepsCommonAndConditionalActionsAndExemptsTheLongTail() throws {
        let catalog = ContextMenuCatalog.shared
        let shown = Set(catalog.referencedIDs(catalog.entries(for: .pane)))
        let retained: Set<ActionID> = [
            "splitRight", "splitDown", "splitLeft", "splitUp", "toggleSplitZoom", "renamePane", "closePane", "newColumnLeft",
            "newColumn", "newRow", "splitBrowserRight", "splitBrowserDown", "pane.moveToNewWorkspace", "pane.moveToNewWindow",
            "swapPaneLeft", "swapPaneRight", "swapPaneUp", "swapPaneDown", "pane.closeOthers", "pane.setBackground",
            "pane.setTint", "pane.clearBackground", "reconnectPane", "palette.copyPaneID", "palette.copyPaneLink",
            "pane.screenshot", "equalizeSplits", "pane.toggleTabBar", "agentPaneZoomIn", "agentPaneZoomOut", "agentPaneZoomReset",
            "remote.openRemote", "agentPane.togglePointerInspector",
        ]
        #expect(shown == retained)
        for id in Self.paneTrimmed {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.isPaletteVisible, "\(id)")
            #expect(descriptor.surfacePlan.contextMenus.isEmpty, "\(id)")
            #expect(descriptor.surfacePlan.contextMenuExemption == .minimalMenu, "\(id)")
        }
    }
}
