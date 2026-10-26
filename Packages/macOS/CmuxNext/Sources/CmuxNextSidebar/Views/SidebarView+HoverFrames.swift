public import CmuxNextInput

extension SidebarView {
    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`): the list and the space bar
    /// hover on a frame interval's first move and once at its frame, at the latest point. Nil: each move
    /// hovers at once.
    public var hoverFrameInput: PointerFrameCoalescers? {
        get { list.hoverFrameInput }
        set {
            list.hoverFrameInput = newValue
            profileBar.hoverFrameInput = newValue
        }
    }
}
