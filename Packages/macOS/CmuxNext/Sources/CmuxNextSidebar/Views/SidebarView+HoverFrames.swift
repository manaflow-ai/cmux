public import CmuxNextWakeups

extension SidebarView {
    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`): the list and the space bar
    /// hover on a frame interval's first move and once at its frame, at the latest point. Nil: each move
    /// hovers at once.
    public var hoverFrameInput: FrameInputCoalescers? {
        get { list.hoverFrameInput }
        set {
            list.hoverFrameInput = newValue
            profileBar.hoverFrameInput = newValue
        }
    }

    /// The list's hovered row changed (nil: off every row): the App prewarms the page it stands for
    /// (`intentPrewarmHover`).
    public var onHoverRow: ((SidebarRowKey?) -> Void)? {
        get { list.onHoverRow }
        set { list.onHoverRow = newValue }
    }
}
