import AppKit
import CmuxNextAgentPane
import CmuxNextTerminal

/// A parked workspace shown again at another size than it was parked at: the window or the sidebar
/// changed meanwhile. Its chats showed their last frames at the old size, then jumped to the new one
/// (Leo 2026-10-20: "we shouldn't be having these wild-ass layout shifts"). The window keeps the
/// outgoing workspace until they drew at the new size (`WindowRootView.show`, `PanePaintHold`).
/// Shown again at the size it was parked at, it shows at once.
///
/// Its terminals likewise: one whose output waited in the daemon while the workspace was hidden draws it first, so
/// the workspace's first frame shows the newest screen (SWITCH FRAMES SF-5, pre-show).
extension WorkspaceContentView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool {
        guard isHidden else { return false }
        if TerminalsCatchingUp(in: self).awaits(predicting: true) { return true }
        guard let host = superview, frame.size != host.bounds.size else { return false }
        return !DrawnPages(in: self).pages.isEmpty
    }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        var left = 2
        let done: () -> Void = { [weak self] in
            left -= 1
            guard left == 0 else { return }
            if let window = self?.window as? ShellWindow { window.afterLayoutPass(body) } else { body() }
        }
        // The pages are asked before the layout that resizes them (they note their new size as they lay out).
        if let host = superview, frame.size != host.bounds.size { DrawnPages(in: self).whenRedrawn(done) } else { done() }
        TerminalsCatchingUp(in: self).whenCaughtUp(done)
        layoutSubtreeIfNeeded()
    }
}

/// The terminals a workspace shows (in no hidden view): the ones a switch to it waits for.
@MainActor
struct TerminalsCatchingUp {
    let terminals: [TerminalHostView]

    init(in root: NSView) {
        var found: [TerminalHostView] = []
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                if let terminal = child as? TerminalHostView { found.append(terminal) } else { visit(child) }
            }
        }
        visit(root)
        terminals = found
    }

    /// One waits now, or (`predicting`, before the switch reveals them) would once shown.
    func awaits(predicting: Bool) -> Bool {
        terminals.contains { $0.awaitsCatchUp || (predicting && $0.catchesUpWhenShown) }
    }

    /// Runs `body` once every terminal that waits drew its newest screen (now with none).
    func whenCaughtUp(_ body: @escaping () -> Void) {
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
