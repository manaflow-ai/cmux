import Foundation

@MainActor
final class SidebarWorkspaceReorderDropOverlayTargetBridge {
    private let views = NSHashTable<SidebarWorkspaceReorderDropView>.weakObjects()
    private var targets: [SidebarWorkspaceReorderDropOverlayTarget] = []

    func attach(_ view: SidebarWorkspaceReorderDropView) {
        views.add(view)
        view.targets = targets
    }

    func updateTargets(_ targets: [SidebarWorkspaceReorderDropOverlayTarget]) {
        self.targets = targets
        for view in views.allObjects {
            view.targets = targets
            view.targetsDidUpdate()
        }
    }
}
