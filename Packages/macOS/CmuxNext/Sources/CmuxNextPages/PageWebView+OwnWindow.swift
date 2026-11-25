public import CmuxNextDesign

/// A cmux page on the Chromium engine draws in Chromium's child window over its pane, not in this view's layer: its
/// pane does not ride a move (``PaneContentOwnWindow``). On WebKit it draws in its layer and rides.
extension PageWebView: PaneContentOwnWindow {
    public var drawsInOwnWindow: Bool { chromiumSession != nil }
}
