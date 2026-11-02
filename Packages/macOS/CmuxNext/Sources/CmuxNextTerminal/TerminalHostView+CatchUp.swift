public import AppKit

/// What a pane or a window that switches to this terminal asks (``TerminalSession/awaitsCatchUp``).
public extension TerminalHostView {
    /// The session of the surface shown here.
    private var shownSession: TerminalSession? {
        subviews.lazy.compactMap { ($0 as? TerminalSurfaceView)?.session }.first
    }

    /// Shown again, it has not drawn the output its owner held while it was hidden.
    var awaitsCatchUp: Bool { shownSession?.awaitsCatchUp ?? false }

    /// Hidden now, it would wait for that output once shown.
    var catchesUpWhenShown: Bool { shownSession?.catchesUpWhenShown ?? false }

    /// Runs `body` once it drew the newest screen (at once when it waits for none).
    func whenCaughtUp(_ body: @escaping () -> Void) {
        guard let session = shownSession else { return body() }
        session.whenCaughtUp(body)
    }
}
