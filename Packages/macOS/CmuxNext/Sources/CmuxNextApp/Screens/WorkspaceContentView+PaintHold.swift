import AppKit
import CmuxNextAgentPane

/// A parked workspace shown again at another size than it was parked at: the window or the sidebar
/// changed meanwhile. Its chats showed their last frames at the old size, then jumped to the new one
/// (Leo 2026-10-20: "we shouldn't be having these wild-ass layout shifts"). The window keeps the
/// outgoing workspace until they drew at the new size (`WindowRootView.show`, `PanePaintHold`).
/// Shown again at the size it was parked at, it shows at once.
extension WorkspaceContentView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool {
        guard isHidden, let host = superview, frame.size != host.bounds.size else { return false }
        return !DrawnPages(in: self).pages.isEmpty
    }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        DrawnPages(in: self).whenRedrawn { [weak self] in
            if let window = self?.window as? ShellWindow { window.afterLayoutPass(body) } else { body() }
        }
        layoutSubtreeIfNeeded()
    }
}
