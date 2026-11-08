/// What a screen shows once per display frame (`ScreenContentView.frameInput`): its strip pan's events
/// (`ScreenContentView.presentPan`) and the presentation the frame tick's input held (`LayoutFrameInput`).
struct ScreenFrameInput {
    /// A strip pan event showed in the current display frame (`presentPan`); the frame's tick clears it
    /// (`displayFrameBegan`).
    var panPresentedInFrame = false
    /// Strip pan events reduced but not shown yet: the next frame tick shows them in one presentation.
    var panPresentationPending = false
    /// Frame ticks the pan still keeps after its last event (`displayFrameBegan`).
    var panTicksLeft = 0
    /// A presentation asked for while the frame tick's input held them (`LayoutViewContext.holdsPresentations`): the
    /// frame's one pass shows it.
    var presentationWaiting = false
    /// A structural change that snapped waits for the next frame tick, its terminals' new sizes drawn ahead in its turn
    /// (`ScreenContentView+SnapFrame`, CLOSE MOTION 3).
    var snapWaitsForContent = false
    /// The panes that change took out, shown as they were until it shows.
    var snapDeparted: [PaneID] = []
    #if DEBUG || CMUX_BENCH_HOOKS
    /// ZOOM VARIANTS film selector (never merged): the held snap is a film zoom's, whose terminals send their final grids
    /// in the key's turn (``PaneHostView`` `drawAhead(sizeChange:keyPress:)` as a key press), not at the landing.
    var filmSnapSendsGrid = false
    /// The film zoom's motion (pictures, masks), started by the presentation that shows its final layout.
    var filmZoomPending: (@MainActor () -> Void)?
    /// The panes a film zoom covers: kept as they are (retired until the unzoom, no teardown, no resize) from the
    /// presentation that shows the zoom, as the current zoom keeps them (`PaneZoomMotion.covered`).
    var filmZoomRetire: [PaneID] = []
    /// Z4 zoom in (ZOOM VARIANTS 2): the covered panes fading out live (their own layers, no copies), shown and visible
    /// until the fade ends, then retired as ``filmZoomRetire`` is. The generation tells a fade's end from a newer zoom's.
    var filmZoomFading: [PaneID] = []
    var filmZoomGeneration = 0
    /// A film zoom's motion plays until this media time (ZOOM VARIANTS 7): set at the zoom (its curve's duration plus
    /// `filmEndGrace`, its deadline, in case no end comes), cleared by its end, its deadline or a press
    /// (``ScreenContentView/filmMotionEnded(_:)``). The window's divider catchers wait for it as for a spring
    /// (`LayoutRootView.catchersWaitForLanding`).
    var filmMotionUntil: Double = 0
    #endif
}
