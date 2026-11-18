public import AppKit
public import CmuxNextDesign

/// A terminal rides its pane's move at a split, a close or a zoom: its surface has the new size in the frame that
/// shows the change, and the pane's clip moves over it.
extension TerminalHostView: PaneCommitMotionRiding {}

/// An unzoom shows the terminal's last frame at its old size while the pane's clip closes: the frame that the
/// surface's layer shows now, by reference. No pixel is copied, and nothing is asked on a frame.
extension TerminalHostView: PaneCommitMotionLastFrameGiving {
    public var paneCommitMotionLastFrame: PaneCommitMotionLastFrame? {
        guard let surface = current, let layer = surface.layer, let frame = surface.presentedFrame else { return nil }
        return PaneCommitMotionLastFrame(contents: frame, gravity: layer.contentsGravity, scale: layer.contentsScale,
                                         rect: convert(surface.bounds, from: surface))
    }
}
