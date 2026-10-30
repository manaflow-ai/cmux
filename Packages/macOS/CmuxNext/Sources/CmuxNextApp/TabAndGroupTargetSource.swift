import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSidebar
import CmuxNextLayout

/// Lists and names tabs, tab groups and workspace groups: the open tab
/// groups of every machine (Add Tab to Group…), the saved ones (Reopen and
/// Delete Saved Tab Group…) and the active window's workspace groups in
/// sidebar order (Move Workspace to Group…). Rename prompts (Rename Tab…,
/// Rename Tab Group…, Rename Group…) start from the target's own name.
/// A right-clicked workspace's Move to Group lists SidebarEdits.joinableGroups.
final class TabAndGroupTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        switch kind {
        case .tabGroup:
            services.machines.allWorkspaces.map(\.0).flatMap { workspace in
                workspace.screens.flatMap(\.panes).flatMap(\.tabGroups).map { group in
                    PaletteTargetOption(id: group.id.rawValue, title: Self.named(group.name), subtitle: workspace.displayName, symbol: "circle.fill")
                }
            }
        case .workspaceGroup:
            workspaceGroups.map { PaletteTargetOption(id: $0.id.rawValue, title: SidebarGroup.named($0.name), symbol: "folder") }
        default:
            next.targets(of: kind)
        }
    }

    /// Reopen and Delete Saved Tab Group… pick a saved group of the machine
    /// they act on (Reopen only one that is not open); any other action
    /// gets the kind's whole list.
    func targets(of kind: ActionTargetKind, for action: ActionID) -> [PaletteTargetOption] {
        guard kind == .tabGroup, action == "tabGroup.reopenSaved" || action == "tabGroup.deleteSaved" else { return targets(of: kind) }
        return services.activeDaemon.store.savedTabGroups.filter { action != "tabGroup.reopenSaved" || $0.openGroup == nil }.map { saved in
            PaletteTargetOption(id: saved.id.rawValue, title: Self.named(saved.name), symbol: "bookmark")
        }
    }

    /// A tab group's name, or the strip's label for an unnamed one.
    private static func named(_ name: String) -> String { name.isEmpty ? ScreenStrings.untitledGroup : name }

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
            name = workspaceGroups.first { $0.id.rawValue == target.id }?.name
        default:
            return next.title(of: target)
        }
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The active window's sidebar groups, personal groups included, in sidebar order.
    private var workspaceGroups: [SidebarGroup] {
        SidebarEdits.groups(in: services.windows.active?.sidebar.model.sections ?? [])
    }

    /// Every pane on every machine.
    private var panes: [PaneModel] {
        services.machines.allWorkspaces.map(\.0).flatMap { $0.screens.flatMap(\.panes) }
    }

    /// Descriptions belong to kinds `next` lists.
    func currentDescription(of target: ActionTargetRef) -> String? {
        next.currentDescription(of: target)
    }
}
