public import CmuxNextInput

extension LayoutRootView {
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): a divider, column-edge
    /// or row-edge drag moves the layout on a frame interval's first event and once more at its frame,
    /// to the latest point, and every event still feeds the release velocity. Nil: each drag event
    /// moves the layout at once.
    public var dragFrameInput: PointerFrameCoalescers? {
        get { context.dragFrameInput }
        set { context.dragFrameInput = newValue }
    }
}
