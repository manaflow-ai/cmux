public import CmuxNextDesign

/// How the pane a split adds comes in (Cmd-D, Cmd-Shift-D, a split of the New Tab page). Debug Settings
/// `motion.split.arrival` (``LayoutTunables/splitArrival``) picks it; the layout reads it in each change turn
/// (`LayoutViewContext.splitArrival`).
///
/// A new dock column and a content handoff (the added pane takes over what its neighbour showed) are spatial
/// changes a person sees rarely: they keep their slide in either choice.
public nonisolated enum SplitArrival: String, Sendable, CaseIterable, TunableChoice {
    /// The default (Lawrence 2026-10-27: "a more subtle animation for the split that is coming in (just an
    /// opacity fade maybe)"; plans/cmux-next/motion-first-principles.md). The key's turn lays the split out once
    /// at its final layout: the new pane at its rest frame, every pane beside it at its new size. The new
    /// pane's layer then fades from 0 to 1 on the render server (`MotionFade.fadeIn`, ease-out), after its
    /// content drew its first frame. No pane frame moves on any display frame.
    case fade
    /// The split spring of plans/cmux-next/split-spring-animation/DESIGN.md: the new pane grows in from a
    /// sliver on its neighbour's edge while the chain springs to its new sizes, laid out on every frame.
    case grow

    /// The longest a split's new pane waits, at opacity 0, for its content's first frame before its fade starts
    /// anyway: one quick motion step, so the key reads as answered even when a terminal is slow to draw.
    static let firstFrameWait: TimeInterval = MotionScale.quick

    public var tunableTitle: String {
        switch self {
        case .fade: "Fade in"
        case .grow: "Grow from the edge"
        }
    }
}
