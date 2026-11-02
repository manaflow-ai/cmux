import AppKit
import CmuxNextAgentPane
import CmuxNextTerminal

/// A parked workspace shown again at another size than it was parked at: the window or the sidebar
/// changed meanwhile. Its chats showed their last frames at the old size, then jumped to the new one
/// (Leo 2026-10-20: "we shouldn't be having these wild-ass layout shifts"). The window keeps the
/// outgoing workspace until they drew at the new size (`WindowRootView.show`, `PanePaintHold`).
/// Shown again at the size it was parked at, it shows at once. Its terminals' held output likewise (SF-5 pre-show).
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
        if let host = superview, frame.size != host.bounds.size { DrawnPages(in: self).whenRedrawn(done) } else { done() }
        TerminalsCatchingUp(in: self).whenCaughtUp(done)
        layoutSubtreeIfNeeded()
    }
}
