import AppKit
import CmuxNextAgentPane

/// A page in a workspace that draws its own frames (a chat's web page). Parked with its workspace,
/// it draws nothing, and shown again it shows the last frame it drew, at the size it drew it, until
/// it lays out again.
@MainActor
protocol WorkspacePageRedrawing: AnyObject {
    /// It drew before. One that has not covers itself with its own loading state.
    var hasDrawnFrame: Bool { get }
    /// Runs `body` once it drew at the size it shows at after the next layout.
    func whenRedrawn(_ body: @escaping () -> Void)
}

extension AgentPaneView: WorkspacePageRedrawing {
    var hasDrawnFrame: Bool { model.hasPainted }

    func whenRedrawn(_ body: @escaping () -> Void) {
        redraw.when(self) { [weak self] in
            if let window = self?.window as? ShellWindow { window.afterLayoutPass(body) } else { body() }
        }
    }
}

/// A parked workspace shown again at another size than it was parked at: the window or the sidebar
/// changed meanwhile. Its chats showed their last frames at the old size, then jumped to the new one
/// (Leo 2026-10-20: "we shouldn't be having these wild-ass layout shifts"). The window keeps the
/// outgoing workspace until they drew at the new size (`WindowRootView.show`, `PanePaintHold`).
/// Shown again at the size it was parked at, it shows at once.
extension WorkspaceContentView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool {
        guard isHidden, let host = superview, frame.size != host.bounds.size else { return false }
        return !drawnPages().isEmpty
    }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        // Asked before the layout that resizes them: a page notes its new size as it lays out.
        let pages = drawnPages()
        guard !pages.isEmpty else { return body() }
        var left = pages.count
        for page in pages {
            page.whenRedrawn {
                left -= 1
                if left == 0 { body() }
            }
        }
        layoutSubtreeIfNeeded()
    }

    /// The pages that drew before in the workspace's shown part: not in a hidden tab or pane, not
    /// in a column scrolled out of the viewport.
    private func drawnPages() -> [any WorkspacePageRedrawing] {
        var found: [any WorkspacePageRedrawing] = []
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                guard let page = child as? any WorkspacePageRedrawing else {
                    visit(child)
                    continue
                }
                if page.hasDrawnFrame, child.convert(child.bounds, to: self).intersects(bounds) { found.append(page) }
            }
        }
        visit(self)
        return found
    }
}
