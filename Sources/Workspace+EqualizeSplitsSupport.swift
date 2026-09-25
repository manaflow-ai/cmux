import Bonsplit
import CmuxPanes
import CmuxSettings
import Foundation

extension Workspace {
    func didProgrammaticallyChangeSplitGeometry() {
        splitTabBar(bonsplitController, didChangeGeometry: bonsplitController.layoutSnapshot())
    }

    func applyInitialSplitDividerPosition(
        _ position: CGFloat?,
        sourcePaneId: PaneID,
        newPaneId: PaneID
    ) {
        guard let position,
              let splitId = splitNodeJoiningPaneIds(
                sourcePaneId.id.uuidString,
                newPaneId.id.uuidString,
                in: bonsplitController.treeSnapshot()
              ).flatMap({ UUID(uuidString: $0.id) }) else { return }
        _ = bonsplitController.setDividerPosition(position, forSplit: splitId, fromExternal: true)
        // The divider moved after bonsplit's didSplitPane projection; re-derive
        // the provisional pane frames from the same pre-split base.
        applyProvisionalSplitPaneGeometry(originalPane: sourcePaneId, newPane: newPaneId)
    }

    /// Rebalances the splits along a newly created split's axis when
    /// `app.equalizeSplitsOnCreate` is on (issue #731).
    ///
    /// This is the shared post-create step for user-initiated splits: the
    /// TabManager split actions (shortcut, menu, context menu, command
    /// palette, Ghostty split passthrough), the browser split action, the
    /// v1/v2 socket split commands, and bonsplit's own split buttons. Session
    /// restore and layout builders skip it because they impose their own
    /// divider positions. Only splits with the new split's orientation move,
    /// so a vertical split never disturbs the widths of side-by-side panes.
    ///
    /// - Returns: `true` when the setting is on and at least one split was
    ///   rebalanced.
    @discardableResult
    func equalizeSplitsAfterCreatingSplitIfEnabled(
        newPanelId: UUID,
        orientation: SplitOrientation,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard)
    ) -> Bool {
        guard let newPaneId = paneId(forPanelId: newPanelId) else { return false }
        return equalizeSplitsAfterCreatingSplitIfEnabled(
            newPaneId: newPaneId,
            orientation: orientation,
            settings: settings
        )
    }

    @discardableResult
    func equalizeSplitsAfterCreatingSplitIfEnabled(
        newPaneId: PaneID,
        orientation: SplitOrientation,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard)
    ) -> Bool {
        guard settings.value(for: SettingCatalog().app.equalizeSplitsOnCreate),
              layoutMode != .canvas,
              !isRemoteTmuxMirror else { return false }
        let result = PaneLayoutService().equalizeSplits(
            in: bonsplitController.treeSnapshot(),
            controller: bonsplitController,
            orientationFilter: orientation.rawValue
        )
        guard result.foundSplit else { return false }
        didProgrammaticallyChangeSplitGeometry()
        // The new split's divider moved after bonsplit's didSplitPane
        // projection; re-derive the provisional pane frames like
        // `applyInitialSplitDividerPosition` does.
        if let sourcePaneId = siblingPaneId(of: newPaneId, in: bonsplitController.treeSnapshot()) {
            applyProvisionalSplitPaneGeometry(originalPane: sourcePaneId, newPane: newPaneId)
        }
        return true
    }

    /// The pane that shares a direct parent split with `paneId`, which right
    /// after a split is the pane it was split from.
    private func siblingPaneId(of paneId: PaneID, in node: ExternalTreeNode) -> PaneID? {
        guard case .split(let split) = node else { return nil }
        let target = paneId.id.uuidString
        if case .pane(let first) = split.first, case .pane(let second) = split.second {
            if first.id == target { return bonsplitController.allPaneIds.first { $0.id.uuidString == second.id } }
            if second.id == target { return bonsplitController.allPaneIds.first { $0.id.uuidString == first.id } }
        }
        return siblingPaneId(of: paneId, in: split.first) ?? siblingPaneId(of: paneId, in: split.second)
    }

    /// The split whose two subtrees separate `firstPaneId` from `secondPaneId`.
    func splitNodeJoiningPaneIds(
        _ firstPaneId: String,
        _ secondPaneId: String,
        in node: ExternalTreeNode
    ) -> ExternalSplitNode? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            let firstContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.first)
            let firstContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.first)
            let secondContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.second)
            let secondContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.second)
            if (firstContainsFirst && secondContainsSecond) || (firstContainsSecond && secondContainsFirst) {
                return splitNode
            }
            return splitNodeJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.first)
                ?? splitNodeJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.second)
        }
    }

    func splitTreeContainsPane(_ paneId: String, in node: ExternalTreeNode) -> Bool {
        switch node {
        case .pane(let pane):
            return pane.id == paneId
        case .split(let split):
            return splitTreeContainsPane(paneId, in: split.first)
                || splitTreeContainsPane(paneId, in: split.second)
        }
    }
}
