import AppKit

/// Provides viewport plumbing while Ghostty owns terminal scrollback.
@MainActor
final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Bonsplit lays out the tab strip outside this viewport, so AppKit must not
        // infer another terminal-content inset from the window title bar.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Keep keyboard routing on the terminal surface; this wrapper is viewport plumbing.
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        // Route wheel gestures to the terminal surface so Ghostty handles scrollback.
        // Letting NSScrollView consume these events moves the wrapper viewport itself,
        // which causes pane-content drift instead of terminal scrollback movement.
        GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: surface scroll")
        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        surfaceView.scrollWheel(with: event)
    }
}
