public import CmuxNextWakeups

extension AddressBarView {
    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`, the App's
    /// `hoverFrameInput`): the suggestion rows hover on a frame interval's first move and once more at
    /// its frame, the row under the latest point. Nil: each move hovers at once.
    public var hoverFrameInput: FrameInputCoalescers? {
        get { panel.hoverFrameInput }
        set { panel.hoverFrameInput = newValue }
    }
}
