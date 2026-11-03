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

/// The terminals a workspace shows on screen (in no hidden view, inside its bounds): the ones a switch to it waits for.
@MainActor
public struct TerminalsCatchingUp {
    public let terminals: [TerminalHostView]

    public init(in root: NSView) {
        var found: [TerminalHostView] = []
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                guard let terminal = child as? TerminalHostView else { visit(child); continue }
                // On screen only: a keep-alive pane scrolled out of the viewport holds no switch.
                if terminal.convert(terminal.bounds, to: root).intersects(root.bounds) { found.append(terminal) }
            }
        }
        visit(root)
        terminals = found
    }

    /// One waits now, or (`predicting`, before the switch reveals them) would once shown.
    public func awaits(predicting: Bool) -> Bool {
        terminals.contains { $0.awaitsCatchUp || (predicting && $0.catchesUpWhenShown) }
    }

    /// Runs `body` once every terminal that waits drew its newest screen (now with none).
    public func whenCaughtUp(_ body: @escaping () -> Void) {
        let waiting = terminals.filter(\.awaitsCatchUp)
        var left = waiting.count
        guard left > 0 else { return body() }
        for terminal in waiting {
            terminal.whenCaughtUp {
                left -= 1
                if left == 0 { body() }
            }
        }
    }
}
