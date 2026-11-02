/// Where a screen's panes stand on a person's resize drag (``ScreenContentView/resizeGesture``).
enum PaneResizeGesturePhase: Equatable {
    /// No drag: the pane contents follow their frames.
    case idle
    /// A divider or edge moves under the pointer.
    case active
    /// Released; the layout the release makes has not reached this screen yet.
    case releasing
    /// The release's layout is here; its spring, if any, has not landed.
    case landing
}
