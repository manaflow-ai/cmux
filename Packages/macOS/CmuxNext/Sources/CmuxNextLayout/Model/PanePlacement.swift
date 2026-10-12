public import CmuxNextDesign
public import CoreGraphics

/// Where a new pane goes, decided from the layout alone so New Pane (Auto
/// Layout) (Ctrl-Cmd-N) and `layout.newPanePlacement: split` behave the
/// same: the largest scrolling pane on screen splits along its longer side
/// (Zellij's new pane). A docked column (side dock or band) never splits.
/// The daemon still owns the result.
public struct PanePlacement {
    public nonisolated init() {}

    /// What opening a new terminal or browser does.
    public nonisolated enum Plan: Hashable, Sendable {
        /// A tab in this pane.
        case tab(in: PaneID)
        /// A new pane splitting this one along the axis.
        case split(PaneID, SplitAxis)
    }

    /// The pane Auto Layout splits and the axis.
    public nonisolated struct Split: Hashable, Sendable {
        public var pane: PaneID
        public var axis: SplitAxis
    }

    /// The plan for a new terminal (`tiles` true) or browser (`tiles` =
    /// `layout.tileBrowsers`) opened while `focused` has the keyboard.
    /// `recent` is the workspace's panes, most recently focused first;
    /// `frames` the shown panes' frames.
    public nonisolated func plan(layout: ScreenLayout, focused: PaneID, recent: [PaneID], frames: [PaneID: CGRect],
                                 placement: NewPanePlacement, tiles: Bool) -> Plan {
        guard placement == .split, tiles, let split = autoSplit(layout: layout, frames: frames, recent: recent) else {
            return .tab(in: focused)
        }
        return .split(split.pane, split.axis)
    }

    /// Zellij's new pane: the largest shown pane of a scrolling column,
    /// split along its longer side (width first on a tie). Equal areas
    /// prefer the most recently focused pane, then visual order. When no
    /// scrolling pane is shown, the most recent scrolling pane (else the
    /// first) splits along its width. Nil only when the screen has no
    /// scrolling pane at all.
    public nonisolated func autoSplit(layout: ScreenLayout, frames: [PaneID: CGRect], recent: [PaneID]) -> Split? {
        let candidates: [PaneID] = switch layout {
        case .splits(let root): root.panes
        case .columns(let columns): columns.filter { $0.dock == nil }.flatMap(\.root.panes)
        }
        var best: (pane: PaneID, frame: CGRect, rank: Int)?
        for (order, pane) in candidates.enumerated() {
            guard let frame = frames[pane], frame.width > 0, frame.height > 0 else { continue }
            // Lower rank wins a tie: recent panes first, then visual order.
            let rank = recent.firstIndex(of: pane) ?? (recent.count + order)
            let area = frame.width * frame.height
            if let current = best {
                let currentArea = current.frame.width * current.frame.height
                guard area > currentArea || (area == currentArea && rank < current.rank) else { continue }
            }
            best = (pane, frame, rank)
        }
        if let best {
            return Split(pane: best.pane, axis: best.frame.width >= best.frame.height ? .horizontal : .vertical)
        }
        guard let fallback = recent.first(where: candidates.contains) ?? candidates.first else { return nil }
        return Split(pane: fallback, axis: .horizontal)
    }
}
