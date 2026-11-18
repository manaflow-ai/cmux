public import AppKit
public import CmuxNextDesign

/// A terminal rides its pane's move at a split, a close or a zoom: its surface has the new size in the frame that
/// shows the change, and the pane's clip moves over it.
extension TerminalHostView: PaneCommitMotionRiding {}
