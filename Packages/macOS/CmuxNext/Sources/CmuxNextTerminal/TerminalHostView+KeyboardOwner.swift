public import AppKit

extension TerminalHostView {
    /// The host of the terminal whose surface view `responder` is; nil for any other responder. A terminal makes its
    /// surface view again when a replay arrives (`TerminalSession`), and its host stays: code that must know whether
    /// the SAME terminal still has the keyboard later compares the host, never the surface view.
    public static func keyboardOwner(of responder: NSResponder) -> AnyObject? {
        (responder as? TerminalSurfaceView)?.superview as? TerminalHostView
    }
}
