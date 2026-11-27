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
    func splitSpaceVerdict(
        splitting paneId: PaneID,
        orientation: SplitOrientation,
        dividerPosition: CGFloat? = nil
    ) -> SplitSpaceVerdict {
        guard layoutMode != .canvas else { return .fits }
        let minimum = splitMinimumPaneSize
        return bonsplitController.treeSnapshot().splitSpaceVerdict(
            splittingPaneId: paneId.id.uuidString,
            orientation: orientation.rawValue,
            minimumExtent: Double(orientation == .horizontal ? minimum.width : minimum.height),
            dividerThickness: Double(bonsplitController.configuration.appearance.dividerThickness),
            dividerPosition: dividerPosition.map(Double.init)
        )
    }

    /// The verdict for splitting the pane that holds `panelId`, or `.fits`
    /// when the panel has no pane (the split fails on its own later).
    func splitSpaceVerdict(
        splittingPanel panelId: UUID,
        orientation: SplitOrientation,
        dividerPosition: CGFloat? = nil
    ) -> SplitSpaceVerdict {
        guard let paneId = paneId(forPanelId: panelId) else { return .fits }
        return splitSpaceVerdict(
            splitting: paneId,
            orientation: orientation,
            dividerPosition: dividerPosition
        )
    }

    /// The single space check for every split Bonsplit starts: UI split
    /// buttons, tab drags, and cmux's programmatic helpers all pass here.
    /// Only restoration and remote-layout projection transactions opt out.
    /// A refused split beeps, like Cmd+D with no room.
    func admitsBonsplitUISplit(of paneId: PaneID, orientation: SplitOrientation) -> Bool {
        admitsSplitSpacePreflight(
            splitting: paneId,
            orientation: orientation,
            dividerPosition: activeSplitSpaceDividerPosition
        )
    }

    /// Cheap gate used before a split helper constructs a live panel. The
    /// Bonsplit delegate repeats this check immediately before mutation as a
    /// backstop against geometry changes between preflight and commit.
    func admitsSplitSpacePreflight(
        splitting paneId: PaneID,
        orientation: SplitOrientation,
        dividerPosition: CGFloat? = nil
    ) -> Bool {
        guard splitSpaceAdmissionBypassDepth == 0,
              splitSpaceVerdict(
                  splitting: paneId,
                  orientation: orientation,
                  dividerPosition: dividerPosition
              ) == .noSpace else { return true }
        NSSound.beep()
        return false
    }

    func withSplitSpaceDividerPosition<Result>(
        _ dividerPosition: CGFloat?,
        _ body: () throws -> Result
    ) rethrows -> Result {
        let previous = activeSplitSpaceDividerPosition
        activeSplitSpaceDividerPosition = dividerPosition
        defer { activeSplitSpaceDividerPosition = previous }
        return try body()
    }

    func withSplitSpaceAdmissionBypass<Result>(_ body: () throws -> Result) rethrows -> Result {
        splitSpaceAdmissionBypassDepth += 1
        defer { splitSpaceAdmissionBypassDepth = max(0, splitSpaceAdmissionBypassDepth - 1) }
        return try body()
    }

    func finishSplitSpaceBorrow(
        originalPaneId: PaneID,
        newPaneId: PaneID,
        orientation: SplitOrientation
    ) {
        guard layoutMode != .canvas else { return }
        let paneKeys = Set([originalPaneId.id.uuidString, newPaneId.id.uuidString])
        let splitFrames = bonsplitController.layoutSnapshot().panes.filter { paneKeys.contains($0.paneId) }
        guard splitFrames.count == paneKeys.count else { return }
        let minimum = splitMinimumPaneSize
        let required = Double(orientation == .horizontal ? minimum.width : minimum.height)
        let extents = splitFrames.map { orientation == .horizontal ? $0.frame.width : $0.frame.height }
        guard extents.allSatisfy({ $0 > 0 }), extents.contains(where: { $0 < required }) else { return }
        equalizeSplitRun(containingNewPane: newPaneId)
    }
}
