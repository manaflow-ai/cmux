import CmuxNextDesign

/// A pane content told about a resize drag, held weakly until it hears the end.
struct PaneResizeGestureListener {
    weak var view: (any PaneResizeGestureFollowing)?
}
