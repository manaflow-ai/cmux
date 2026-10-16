import CmuxCloud
import AppKit
import CmuxFoundation

extension SidebarBonsplitTabWorkspaceDropView {
    /// SwiftUI and NSTableView sidebars share this same native destination.
    func updateOwnershipFeedback(action: SidebarDropPlanner.WorkspaceDropAction?, pasteboard: NSPasteboard) {
        guard case .existingWorkspace(let workspaceID) = action,
              let app = AppDelegate.shared,
              let workspace = app.workspaceFor(tabId: workspaceID) else {
            ownershipFeedback.clear()
            return
        }
        let resolver = PaneTransferSourceResolver()
        let rejection: SurfaceTransferRejection?
        if let transfer = resolver.transfer(from: pasteboard), let source = resolver.source(for: transfer) {
            rejection = workspace.surfaceDropRejection(transfer, source: source)
        } else {
            rejection = workspace.surfaceOwnershipPolicy.rejection(for: nil)
        }
        ownershipFeedback.update(rejection, over: self)
    }
}
