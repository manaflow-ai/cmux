import AppKit

/// Preserves terminal interaction semantics in empty space around capped content.
final class TerminalPaneBackgroundView: NSView {
    weak var terminalSurfaceView: GhosttyNSView?
    weak var terminalScrollView: GhosttyScrollView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        terminalSurfaceView?.acceptsFirstMouse(for: event) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        terminalSurfaceView?.focusFromPointerDown()
    }

    override func rightMouseDown(with event: NSEvent) {
        terminalSurfaceView?.focusFromPointerDown()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        terminalSurfaceView?.paneContextMenu(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        terminalScrollView?.scrollWheel(with: event)
    }
}
