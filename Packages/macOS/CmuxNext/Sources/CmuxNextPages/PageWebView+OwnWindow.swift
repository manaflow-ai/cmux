public import CmuxNextDesign

/// A cmux page on the Chromium engine draws in Chromium's child window over its pane, not in this view's layer: its
/// pane does not ride a move (``PaneContentOwnWindow``). On WebKit, or hosted in the window's layer tree (an agent
/// chat on Chromium), it draws in its layer and rides: Cmd-Shift-Enter on a chat zooms with motion.
extension PageWebView: PaneContentOwnWindow {
    public var drawsInOwnWindow: Bool { chromiumSession?.page.drawsInOwnWindow ?? false }
}
