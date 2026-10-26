public import CmuxNextWakeups

extension LayoutRootView {
    /// The windows' frame-aligned input (feature `pointerFrameDrags`): a divider, column-edge or
    /// row-edge drag moves the layout at most once per frame, to the frame's latest point, and
    /// every event still feeds the release velocity. Nil: each drag event moves the layout at once.
    public var dragFrameInput: FrameInputCoalescers? {
        get { context.dragFrameInput }
        set { context.dragFrameInput = newValue }
    }
}
