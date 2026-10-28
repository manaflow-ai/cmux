public import CmuxNextInput
public import CmuxNextWakeups

extension SidebarView {
    /// The app's one input tap (the App injects it): the list hears the app's left presses and releases there,
    /// so a press whose release went elsewhere ends (`SidebarListView+PointerEnd`), and the list's scroll view and
    /// the space bar hear their window's scrolls there to page the spaces (`SidebarSwipeFeed`).
    public var inputTap: InputEventTap? {
        get { list.inputTap }
        set {
            list.inputTap = newValue
            scrollView.inputTap = newValue
            profileBar.inputTap = newValue
        }
    }

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

    /// A press on a list row: the workspace row it switches to only on the release, nil otherwise. The App
    /// prewarms the page it stands for (`intentPrewarmPress`).
    public var onPressRow: ((SidebarRowKey?) -> Void)? {
        get { list.onPressRow }
        set { list.onPressRow = newValue }
    }
}
