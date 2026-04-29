import AppKit
import SwiftUI

struct TabContextMenuState {
    let isPinned: Bool
    let isUnread: Bool
    let isBrowser: Bool
    let isTerminal: Bool
    let hasCustomTitle: Bool
    let canCloseToLeft: Bool
    let canCloseToRight: Bool
    let canCloseOthers: Bool
    let canMoveToLeftPane: Bool
    let canMoveToRightPane: Bool
    let isZoomed: Bool
    let hasSplits: Bool
    let shortcuts: [TabContextAction: KeyboardShortcut]

    var canMarkAsUnread: Bool {
        !isUnread
    }

    var canMarkAsRead: Bool {
        isUnread
    }
}

struct WorkspacePaneActionEligibilityFacts {
    let paneId: PaneID
    let tabs: [WorkspaceLayout.Tab]
    let canMoveToLeftPane: Bool
    let canMoveToRightPane: Bool
    let isZoomed: Bool
    let hasSplits: Bool
    let shortcuts: [TabContextAction: KeyboardShortcut]

    let canCloseToLeftByIndex: [Bool]
    let canCloseToRightByIndex: [Bool]
    let canCloseOthersByIndex: [Bool]

    init(
        paneId: PaneID,
        tabs: [WorkspaceLayout.Tab],
        canMoveToLeftPane: Bool,
        canMoveToRightPane: Bool,
        isZoomed: Bool,
        hasSplits: Bool,
        shortcuts: [TabContextAction: KeyboardShortcut]
    ) {
        self.paneId = paneId
        self.tabs = tabs
        self.canMoveToLeftPane = canMoveToLeftPane
        self.canMoveToRightPane = canMoveToRightPane
        self.isZoomed = isZoomed
        self.hasSplits = hasSplits
        self.shortcuts = shortcuts

        var prefixUnpinned = Array(repeating: 0, count: tabs.count + 1)
        for index in tabs.indices {
            let unpinnedDelta = tabs[index].isPinned ? 0 : 1
            prefixUnpinned[index + 1] = prefixUnpinned[index] + unpinnedDelta
        }
        let totalUnpinned = prefixUnpinned[tabs.count]

        var canCloseLeft: [Bool] = []
        var canCloseRight: [Bool] = []
        var canCloseOthers: [Bool] = []
        canCloseLeft.reserveCapacity(tabs.count)
        canCloseRight.reserveCapacity(tabs.count)
        canCloseOthers.reserveCapacity(tabs.count)

        for index in tabs.indices {
            let leftUnpinned = prefixUnpinned[index]
            let rightUnpinned = totalUnpinned - prefixUnpinned[index + 1]
            let selfUnpinned = tabs[index].isPinned ? 0 : 1
            let otherUnpinned = totalUnpinned - selfUnpinned

            canCloseLeft.append(leftUnpinned > 0)
            canCloseRight.append(rightUnpinned > 0)
            canCloseOthers.append(otherUnpinned > 0)
        }

        canCloseToLeftByIndex = canCloseLeft
        canCloseToRightByIndex = canCloseRight
        canCloseOthersByIndex = canCloseOthers
    }

    func contextMenuState(for tab: WorkspaceLayout.Tab, at index: Int) -> TabContextMenuState {
        let canCloseToLeft = canCloseToLeftByIndex.indices.contains(index) ? canCloseToLeftByIndex[index] : false
        let canCloseToRight = canCloseToRightByIndex.indices.contains(index) ? canCloseToRightByIndex[index] : false
        let canCloseOthers = canCloseOthersByIndex.indices.contains(index) ? canCloseOthersByIndex[index] : false

        return TabContextMenuState(
            isPinned: tab.isPinned,
            isUnread: tab.showsNotificationBadge,
            isBrowser: tab.kind == .browser,
            isTerminal: tab.kind == .terminal,
            hasCustomTitle: tab.hasCustomTitle,
            canCloseToLeft: canCloseToLeft,
            canCloseToRight: canCloseToRight,
            canCloseOthers: canCloseOthers,
            canMoveToLeftPane: canMoveToLeftPane,
            canMoveToRightPane: canMoveToRightPane,
            isZoomed: isZoomed,
            hasSplits: hasSplits,
            shortcuts: shortcuts
        )
    }
}
