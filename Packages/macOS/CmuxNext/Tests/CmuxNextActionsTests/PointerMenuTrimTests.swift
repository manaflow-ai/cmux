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

    @Test func theTabMenuDropsFourteenLongTailRows() throws {
        let catalog = ContextMenuCatalog.shared
        let shown = Set(catalog.referencedIDs(catalog.entries(for: .tab)))
        #expect(shown.isDisjoint(with: Self.tabTrimmed))
        // Includes every More/Copy row and every target-dependent action.
        let retained: Set<ActionID> = [
            // agent.share: Share Chat with Guest, a tab-menu row #27959 added after this list was written.
            "agent.share", "agentChat.copyIdentifier", "agentChat.subagentLimit", "agentPane.togglePointerInspector",
            "browser.editSource", "browser.openInChromium", "browserProfile.duplicateTab", "browserProfile.moveTab",
            "closeOtherTabsInPane", "closeTab", "closeTabsToLeft",
            "closeTabsToRight", "disconnectRemoteTab", "duplicateTab", "file.openAsPage",
            "home.messageAbout", "moveSurfaceLeft", "moveSurfaceRight",
            "moveSurfaceToNextPane", "moveSurfaceToPaneDown", "moveSurfaceToPaneLeft",
            "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPreviousPane",
            "newSurface", "newTab.atEnd", "newTab.atStart",
            "newTab.ofKind", "newTab.toRight", "openBrowser.chromium",
            "palette.clearTabName", "palette.copyIdentifiers", "palette.copyPaneID",
            "palette.copyPaneLink", "palette.copySurfaceID", "palette.copySurfaceLink",
            "palette.moveTabToNewWorkspace", "palette.toggleTabPin", "reloadTab",
            "renameTab", "tab.clearIcon", "tab.moveToNewColumn",
            "tab.moveToNewDockColumn", "tab.moveToNewSplit", "tab.moveToNewWindow",
            "tab.moveToWorkspace", "tab.pictureInPicture", "tab.restart",
            "tab.setIcon", "tab.setTint", "tab.showResources",
            "tab.stash", "tab.stashOthers", "tab.stashToRight",
            "tabGroup.addTab", "tabGroup.create", "tabGroup.removeTab",
            "toggleTabAudioMute",
        ]
        #expect(shown == retained)
        for id in Self.tabTrimmed {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(!descriptor.surfacePlan.contextMenus.contains { $0.context == .tab })
            if descriptor.surfacePlan.contextMenus.isEmpty {
                #expect(descriptor.surfacePlan.contextMenuExemption == .pointerMenuTrim, "\(id)")
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
            #expect(descriptor.surfacePlan.contextMenuExemption == .pointerMenuTrim, "\(id)")
        }
    }
}
