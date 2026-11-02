import AppKit
import CmuxNextAgentPane
import CmuxNextTerminal

/// A parked workspace shown again at another size than it was parked at: its chats showed their last frames at the
/// old size, then jumped (Leo 2026-10-20: "we shouldn't be having these wild-ass layout shifts"). The window keeps
/// the outgoing workspace until they drew at the new size (`WindowRootView.show`, `PanePaintHold`), and until its
/// terminals drew the output held while hidden (SF-5 pre-show); otherwise it shows at once.
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
        if let parkedSize, parkedSize != frame.size { DrawnPages(in: self).whenRedrawn(done) } else { done() }
        TerminalsCatchingUp(in: self).whenCaughtUp(done)
        layoutSubtreeIfNeeded()
    }
}
