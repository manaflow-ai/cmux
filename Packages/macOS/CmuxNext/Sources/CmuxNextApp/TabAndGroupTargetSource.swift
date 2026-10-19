import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSidebar

/// Names tabs, tab groups and workspace groups for rename prompts (Rename
/// Tab…, Rename Tab Group…, Rename Group…), which start from the target's
/// own name. It lists nothing itself: pickers of these kinds (Go to Tab…,
/// Add Tab to Group…, Reopen and Delete Saved Tab Group…) keep the lists
/// from `next`; Move to Group lists SidebarEdits.joinableGroups.
final class TabAndGroupTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        next.targets(of: kind)
    }

    /// The name the strip or sidebar shows; nil for an untitled tab, whose
    /// "Terminal" label is not a name.
    func title(of target: ActionTargetRef) -> String? {
        let name: String?
        switch target.kind {
        case .tab:
            name = panes.flatMap(\.tabs).first { $0.id == target.id }?.displayTitle
        case .tabGroup:
            name = panes.flatMap(\.tabGroups).first { $0.id.rawValue == target.id }?.name
        case .workspaceGroup:
            name = SidebarEdits.groups(in: services.windows.active?.sidebar.model.sections ?? []).first { $0.id.rawValue == target.id }?.name
        default:
            return next.title(of: target)
        }
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every pane on every machine.
    private var panes: [PaneModel] {
        services.machines.allWorkspaces.map(\.0).flatMap { $0.screens.flatMap(\.panes) }
    }
}
