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
            // agent.share: Share Chat with Guest, a tab-menu row #27959 added after this list was written;
            // agent.share.invite: Invite People..., the invite sheet's tab-menu row.
            "agent.share", "agent.share.invite", "agentChat.copyIdentifier", "agentChat.subagentLimit",
            "browser.editSource", "browser.openInChromium", "browserProfile.duplicateTab", "browserProfile.moveTab",
            "closeOtherTabsInPane", "closeTab", "closeTabsToLeft",
            "closeTabsToRight",
            // customize.open: Customize…, the row #43407 put on each big part's right-click menu (Leo: "you should
            // maybe be even able to right click customize on anything").
            "customize.open",
            "disconnectRemoteTab", "duplicateTab", "file.openAsPage",
            "home.messageAbout",
            // macScreen.open, macScreen.stopViewing: the Screen Sharing rows that #42789 put into the tab menu.
            "macScreen.open", "macScreen.stopViewing",
            "moveSurfaceLeft", "moveSurfaceRight",
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
        // cloud.team.copyLink: Copy Cloud Session Link, a tab-menu row from #40159. The catalog of the pinned
        // library can be older than that change, so the test expects the id exactly when the catalog has it. When
        // the pinned library has the row, a change puts the id into `retained` and takes these 2 lines out.
        let pinned: Set<ActionID> = ActionCatalog.all.contains { $0.id == "cloud.team.copyLink" } ? ["cloud.team.copyLink"] : []
        // Point at Element (ask-5077a4ec48) is on the tab menu once the pinned catalog carries it.
        #expect(shown.subtracting(["agentPane.togglePointerInspector"]) == retained.union(pinned))
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
        // The floating pane rows can be in the catalog before the App code that runs them (`FloatingPanePlaceholders`):
        // no menu shows such a row, so it is not in this set. The change that binds their handlers puts each of them
        // that the pane menu shows into `retained` and takes the subtraction out.
        let shown = Set(catalog.referencedIDs(catalog.entries(for: .pane))).subtracting(FloatingPanePlaceholders.ids)
        let retained: Set<ActionID> = [
            "splitRight", "splitDown", "splitLeft", "splitUp", "toggleSplitZoom", "renamePane", "closePane", "newColumnLeft",
            "newColumn", "newRow", "splitBrowserRight", "splitBrowserDown", "pane.moveToNewWorkspace", "pane.moveToNewWindow",
            "swapPaneLeft", "swapPaneRight", "swapPaneUp", "swapPaneDown", "pane.closeOthers", "pane.setBackground",
            "pane.setTint", "pane.clearBackground", "reconnectPane", "palette.copyPaneID", "palette.copyPaneLink",
            "pane.screenshot", "equalizeSplits", "pane.toggleTabBar", "agentPaneZoomIn", "agentPaneZoomOut", "agentPaneZoomReset",
            "remote.openRemote",
            // macScreen.open: Open Screen Sharing, the row that #42789 put into the pane menu.
            "macScreen.open",
            // customize.open: Customize…, the row #43407 put on each big part's right-click menu.
            "customize.open",
        ]
        // New ▸ Kind ▸ place: the four kind submenus and their forty places (NewPlacementActionCatalog).
        // Point at Element (ask-5077a4ec48) is on the pane menu once the pinned catalog carries it.
        #expect(shown.subtracting(["agentPane.togglePointerInspector"])
            == retained.union(ActionID.newPlacementSubmenus).union(ActionID.newPlacementActions))
        for id in Self.paneTrimmed {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.isPaletteVisible, "\(id)")
            #expect(descriptor.surfacePlan.contextMenus.isEmpty, "\(id)")
            #expect(descriptor.surfacePlan.contextMenuExemption == .pointerMenuTrim, "\(id)")
        }
    }
}
