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

    /// Feature `stripPanResampling` (p04-input-041): a trackpad pan of the column strip on its motion
    /// container shows at each display frame, at the offset resampled at the frame's time; the snap and
    /// the fling read the real events. False: each pan event shows at once.
    public var resamplesStripPan: Bool {
        get { context.resamplesStripPan }
        set { context.resamplesStripPan = newValue }
    }
}
