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
    /// The held snap is a key press's (its terminals' grids went with their sizes): it shows only once its contents drew
    /// their programs' redraws, or waited as long as they may (``ScreenContentView/heldSnapAwaitsContent()``, RESIZE P0 20).
    var snapAwaitsPrograms = false
    /// Frame ticks the held snap waited for its contents.
    var snapRefreshesWaited = 0
    /// The panes that change took out, shown as they were until it shows.
    var snapDeparted: [PaneID] = []
    /// The dividers that change took out, shown where they were until it shows.
    var snapDepartedDividers: [DividerHandleView] = []
    /// The panes that change brings back from a zoom's cover: hidden until it shows, then shown at their places.
    var snapReturning: [PaneID] = []
    /// A layout change reconciled that no pass has begun to show. The pass that shows it brings along what follows the
    /// panes (``ScreenContentView/beginShowingChange()``): the docks' backdrops, the stacking order, the rings and dims.
    var changeIsUnshown = false
    /// The rings and dims the model asked for while that change was not shown: applied in the pass that shows it.
    var heldChrome: (@MainActor () -> Void)?
    /// The producers a change resized (``PaneCommitSurface``) that have not all reported ready, by pane: whether each
    /// reported, and the change that asked them (a newer change of the pane makes an older report void). A pane stays
    /// here from the change's turn until its last producer reports, which can be after the change showed (a late pane).
    var commitSurfaces: [PaneID: (generation: UInt64, ready: [Bool])] = [:]
    var commitGeneration: UInt64 = 0
    /// The panes the held change resizes and waits for (``commitSurfaces``), at most `ScreenContentView.commitBound` ticks.
    var commitAwaited: Set<PaneID> = []
}
