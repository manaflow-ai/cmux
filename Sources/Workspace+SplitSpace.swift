import AppKit
import Bonsplit
import CmuxPanes
import Foundation

/// Split admission (#15371): a split may not leave a pane smaller than its
/// tab bar plus a few terminal rows. A split that cannot fit in place first
/// borrows room from the panes it stacks with; one that still cannot fit is
/// refused, the way tmux answers "no space for new pane".
extension Workspace {
    /// Terminal rows a pane keeps below its tab bar.
    static let splitMinimumTerminalRows: CGFloat = 3
    /// Row height at the default terminal font, used for the minimum height.
    static let splitNominalTerminalRowHeight: CGFloat = 17
    /// Width of about twenty terminal columns at the default font.
    static let splitMinimumPaneWidth: CGFloat = 160

    /// The smallest pane a split may create. It is never below bonsplit's
    /// divider-drag minimum, so a fresh split never starts smaller than a
    /// drag could make it.
    var splitMinimumPaneSize: CGSize {
        let appearance = bonsplitController.configuration.appearance
        let contentHeight = appearance.tabBarHeight
            + Self.splitMinimumTerminalRows * Self.splitNominalTerminalRowHeight
        return CGSize(
            width: max(appearance.minimumPaneWidth, Self.splitMinimumPaneWidth),
            height: max(appearance.minimumPaneHeight, contentHeight)
        )
    }

    /// Whether splitting `paneId` along `orientation` fits the minimum pane
    /// size, measured from bonsplit's current layout. Canvas workspaces place
    /// panes freely, so they always fit.
    func splitSpaceVerdict(splitting paneId: PaneID, orientation: SplitOrientation) -> SplitSpaceVerdict {
        guard layoutMode != .canvas else { return .fits }
        let minimum = splitMinimumPaneSize
        return bonsplitController.treeSnapshot().splitSpaceVerdict(
            splittingPaneId: paneId.id.uuidString,
            orientation: orientation.rawValue,
            minimumExtent: Double(orientation == .horizontal ? minimum.width : minimum.height),
            dividerThickness: Double(bonsplitController.configuration.appearance.dividerThickness)
        )
    }

    /// The verdict for splitting the pane that holds `panelId`, or `.fits`
    /// when the panel has no pane (the split fails on its own later).
    func splitSpaceVerdict(splittingPanel panelId: UUID, orientation: SplitOrientation) -> SplitSpaceVerdict {
        guard let paneId = paneId(forPanelId: panelId) else { return .fits }
        return splitSpaceVerdict(splitting: paneId, orientation: orientation)
    }

    /// Completes a split admitted as `.fitsAfterEqualizingRun`: when the new
    /// pane came out below the minimum, equalizes the run that now holds it.
    /// A split that fit in place is left as it is, so this is safe to call
    /// after any admitted split. An explicit divider position from the caller
    /// wins, so the run is left alone then.
    func finishSplitSpaceBorrow(
        newPanelId: UUID,
        orientation: SplitOrientation,
        explicitDividerPosition: CGFloat? = nil
    ) {
        guard explicitDividerPosition == nil,
              let newPaneId = paneId(forPanelId: newPanelId) else { return }
        finishSplitSpaceBorrow(newPaneId: newPaneId, orientation: orientation)
    }

    /// The space check for splits bonsplit starts itself (its split buttons
    /// and tab drags to a pane edge). cmux's own split paths check before
    /// they reach bonsplit and mark themselves programmatic, so they pass.
    /// A refused UI split beeps, like Cmd+D with no room.
    func admitsBonsplitUISplit(of paneId: PaneID, orientation: SplitOrientation) -> Bool {
        guard !isProgrammaticSplit,
              activeMovingTabSplitFocusIntent == nil,
              splitSpaceVerdict(splitting: paneId, orientation: orientation) == .noSpace else { return true }
        NSSound.beep()
        return false
    }

    func finishSplitSpaceBorrow(newPaneId: PaneID, orientation: SplitOrientation) {
        guard layoutMode != .canvas else { return }
        let paneKey = newPaneId.id.uuidString
        guard let frame = bonsplitController.layoutSnapshot().panes.first(where: { $0.paneId == paneKey })?.frame
        else { return }
        let minimum = splitMinimumPaneSize
        let extent = orientation == .horizontal ? frame.width : frame.height
        let required = Double(orientation == .horizontal ? minimum.width : minimum.height)
        guard extent > 0, extent < required else { return }
        equalizeSplitRun(containingNewPane: newPaneId)
    }
}
