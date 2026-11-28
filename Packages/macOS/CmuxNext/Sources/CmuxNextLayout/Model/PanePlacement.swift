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
    public nonisolated struct Split: Hashable, Sendable, Decodable {
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
    /// Run by cmux-layout-reducer (`layout_model_auto_split`; `schemas/layout-model/vectors.json`).
    public nonisolated func autoSplit(layout: ScreenLayout, frames: [PaneID: CGRect], recent: [PaneID]) -> Split? {
        struct Frame: Encodable { var x, y, width, height: Double }
        struct Request: Encodable { var layout: ScreenLayout, frames: [String: Frame], recent: [PaneID] }
        struct Reply: Decodable { var split: Split? }
        var shown: [String: Frame] = [:]
        for (pane, frame) in frames {
            shown[pane.rawValue] = Frame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        }
        let reply: Reply? = LayoutRules.call("layout_model_auto_split", Request(layout: layout, frames: shown, recent: recent))
        return reply?.split
    }
}
