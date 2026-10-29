public import CmuxNextInput
public import CmuxNextWakeups

extension LayoutRootView {
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): a divider, column-edge
    /// or row-edge drag moves the layout on a frame interval's first event and once more at its frame,
    /// to the latest point, and every event still feeds the release velocity. Nil: each drag event
    /// moves the layout at once.
    public var dragFrameInput: FrameInputCoalescers? {
        get { context.dragFrameInput }
        set { context.dragFrameInput = newValue }
    }

    /// Makes a divider drag's resampler, asked once per drag on mouse-down (feature `resampledDrags`,
    /// `input.resampleDrags`): the divider, column edge or row edge is drawn at the pointer resampled at
    /// each frame's time, while the snap, the release velocity and the release read real points. Nil
    /// (the default), under Reduce Motion, or without ``dragFrameInput``: drawn at the real pointer.
    public var dragResampler: () -> DragResampler? {
        get { context.dragResampler }
        set { context.dragResampler = newValue }
    }

    /// A new drag's resampler for a drag the layout shows (a pane-swap preview): ``dragResampler``'s,
    /// or nil under Reduce Motion.
    public func newDragResampler() -> DragResampler? {
        context.newDragResampler()
    }

    /// Sets ``dragFrameInput`` and ``dragResampler`` together (the app's composition root).
    public func setDragInput(frames: FrameInputCoalescers?, resampler: @escaping () -> DragResampler?) {
        dragFrameInput = frames
        dragResampler = resampler
    }

    /// Feature `stripPanResampling`: a trackpad pan of the column strip on its motion
    /// container shows at each display frame, at the offset resampled at the frame's time; the snap and
    /// the fling read the real events. False: each pan event shows at once.
    public var resamplesStripPan: Bool {
        get { context.resamplesStripPan }
        set { context.resamplesStripPan = newValue }
    }
}
