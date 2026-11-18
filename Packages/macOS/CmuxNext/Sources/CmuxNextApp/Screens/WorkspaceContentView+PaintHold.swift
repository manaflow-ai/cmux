import AppKit
import CmuxNextAgentPane

/// The window keeps the outgoing workspace (`WindowRootView.show`, `PanePaintHold`) until this one's first frame is its
/// content (`WorkspaceFirstFrame`): its shown pages that never painted (a cold or new workspace's chat or New Tab page),
/// and, shown again at another size than it was parked at, its chats at the new size (Leo 2026-10-20: "we shouldn't be
/// having these wild-ass layout shifts"). Shown again at the size it was parked at, every page painted, it shows at once.
extension WorkspaceContentView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool {
        let resized = isHidden && superview.map { frame.size != $0.bounds.size } == true
        return WorkspaceFirstFrame(of: self).awaits(resized: resized, prerendered: !isHidden && isParkedOffScreen) // Cmd-N's reserved view
    }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        WorkspaceFirstFrame(of: self).whenReady { [weak self] in // lays out, now or in the window's pass
            if let window = self?.window as? ShellWindow { window.afterLayoutPass(body) } else { body() }
        }
    }
}
