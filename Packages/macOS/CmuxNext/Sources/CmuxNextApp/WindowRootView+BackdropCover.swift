import AppKit
import CmuxNextLayout

extension WindowRootView {
    /// Tells the backdrop which columns sit over the art, so a painting's subject lands where it
    /// can be seen: the sidebar, and a workspace's docked agent chat (Leo, 2026-10-18).
    func updateBackdropCover() {
        var covered: [ClosedRange<CGFloat>] = []
        if !sidebarHidden, !sidebar.isHidden, sidebar.frame.width > 0.5 {
            let frame = backdropView.convert(sidebar.frame, from: self)
            covered.append(frame.minX...frame.maxX)
        }
        if let layout = (content as? WorkspaceContentView)?.layoutView as? LayoutRootView, let column = layout.agentChatColumnInWindow {
            let frame = backdropView.convert(column, from: nil)
            covered.append(frame.minX...frame.maxX)
        }
        backdropView.coveredColumns = covered
    }

    /// Follows the agent chat column of whatever workspace this window shows.
    func observeAgentChatColumn() -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: LayoutRootView.agentChatColumnDidChange, object: nil, queue: .main) { [weak self] note in
            let window = (note.object as? NSView)?.window
            // main-proof: the observer runs on the main queue (queue: .main)
            MainActor.assumeIsolated {
                guard let self, window == nil || window === self.window else { return }
                self.updateBackdropCover()
            }
        }
    }
}
