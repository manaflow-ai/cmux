public import CmuxNextDesign

/// How a split's new pane comes in (Cmd-D, Cmd-Shift-D, a split of the New Tab page) and how a pane close lays out
/// (Cmd-W on a pane's last tab, Close Pane). Debug Settings
/// `motion.split.arrival` (``LayoutTunables/splitArrival``) picks it; the layout reads it in each change turn
/// (`LayoutViewContext.splitArrival`).
///
/// A new dock column is a spatial change a person sees rarely: it keeps its growth from the screen edge in either
/// choice. A content handoff (the added pane takes over what its neighbour showed) fades the pane with the new
/// content in at its rest with ``fade``, and slides it in from the screen edge with ``grow``.
public nonisolated enum SplitArrival: String, Sendable, CaseIterable, TunableChoice {
    /// The default (Lawrence 2026-10-27: "a more subtle animation for the split that is coming in (just an
    /// opacity fade maybe)"; plans/cmux-next/motion-first-principles.md). The key's turn lays the split out once
    /// at its final layout: the new pane at its rest frame, every pane beside it at its new size. The new
    /// pane's layer fades from 0 to 1 on the render server from that turn (`MotionFade.fadeIn`, ease-out), on its
    /// own background; its content fades in when it first draws (`LayoutPaneContentProvider.paneArrived`). No pane
    /// frame moves on any display frame. A pane close is its inverse: laid out once at the final layout, the closed
    /// pane gone and its neighbours at their new sizes in the key's turn, nothing moving (so is a pane moved to
    /// another screen, which leaves this one the same way, `PaneArrival.departing`).
    case fade
    /// The split spring of plans/cmux-next/split-spring-animation/DESIGN.md: the new pane grows in from a
    /// sliver on its neighbour's edge while the chain springs to its new sizes, laid out on every frame; a close
    /// springs the neighbours into the closed pane's space the same way.
    case grow

    public var tunableTitle: String {
        switch self {
        case .fade: "One layout, new pane fades in"
        case .grow: "Spring from the edge"
        }
    }
}
