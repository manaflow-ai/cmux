import AppKit
public import CmuxNextDesign

/// A person's divider or edge drag of Home's pane, and a live resize of its window, resize the pane on every display
/// frame (`ScreenContentView+ResizeGesture`, `ScreenContentView+WindowLiveResize`): the transcript's host takes its
/// live-resize paths from the start to the landing (`MessagesLabHomeView.followPaneResize`), so its empty field keeps
/// its text width and the clip its unmasked layer until the pane's frame is final (a divider drag keeps a mask that
/// fades the rows under the top). A host out of its window ends the drag's paths itself (`HostView.viewDidMoveToWindow`).
extension HomeNativeTranscriptView: PaneResizeGestureFollowing {
    public func paneResizeGestureDidChange(active: Bool) {
        transcript.followPaneResize(active)
    }
}
