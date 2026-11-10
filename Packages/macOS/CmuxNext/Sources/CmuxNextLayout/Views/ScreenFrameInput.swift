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
}
