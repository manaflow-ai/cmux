import AppKit

extension NSWindow {
    /// Configures this window as a standard cmux top-level *peer* window.
    ///
    /// Peer windows — Settings, the Config editor, About — sit at
    /// `NSWindow.Level.normal` and obey standard macOS window ordering: clicking
    /// any sibling window (including the main terminal window) brings it forward
    /// and lets the peer recede behind it. This is the default every top-level
    /// window the user opens should adopt.
    ///
    /// It exists as a single, greppable seam so that "this is an ordinary
    /// top-level window" is stated explicitly rather than left implicit. The
    /// only sanctioned way to float a window above its siblings is to set
    /// `level = .floating` deliberately at the call site with a comment
    /// justifying it (e.g. DEBUG HUD/lab panels). Accidentally inheriting a
    /// floating level — via an `NSPanel` default or a stray `level = .floating`
    /// — is what produced the "Settings floats above the main window forever"
    /// bug (https://github.com/manaflow-ai/cmux/issues/5081).
    ///
    /// - Note: A plain `NSWindow` / SwiftUI `Window` scene already defaults to
    ///   `.normal`; calling this makes the invariant explicit and guards against
    ///   a later change (or a child-window attachment) silently re-floating the
    ///   window.
    @MainActor
    func adoptCmuxPeerWindowLevel() {
        level = .normal
    }
}
