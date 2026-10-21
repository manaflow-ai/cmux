import AppKit
import CmuxNextDesign

extension ShellWindow {
    /// The sidebar is sliding open or closed, which moves the content edge on
    /// every display frame, so every pane in the window is mid-motion even
    /// though none of them sits on a layout spring of its own
    /// (`ContentAreaMotionHosting`, `NSView.isInPaneMotion`). Terminals read
    /// this to hold their grid report until the slide lands, which is one PTY
    /// resize and shell redraw instead of one per frame.
    var isContentAreaInMotion: Bool { (contentView as? WindowRootView)?.isContentAreaInMotion ?? false }
}
