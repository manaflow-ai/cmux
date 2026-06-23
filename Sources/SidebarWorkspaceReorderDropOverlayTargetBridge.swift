import Foundation

@MainActor
final class SidebarWorkspaceReorderDropOverlayTargetBridge {
    private weak var view: SidebarWorkspaceReorderDropView?
    private var targets: [SidebarWorkspaceReorderDropOverlayTarget] = []

    func attach(_ view: SidebarWorkspaceReorderDropView) {
        self.view = view
        view.targets = targets
    }

    func updateTargets(_ targets: [SidebarWorkspaceReorderDropOverlayTarget]) {
        self.targets = targets
        view?.targets = targets
        guard !targets.isEmpty else { return }
        view?.performPendingDropIfPossible()
    }
}
