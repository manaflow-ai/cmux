import CmuxNextActions
import CmuxNextPalette

/// Palette target lists for screen actions: the focused workspace's screen
/// groups (Add Screen to Group…) and every workspace (Move Screen to
/// Workspace…). Other kinds fall through to `next`.
final class ScreenTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        switch kind {
        case .screenGroup:
            guard let workspace = services.windows.active?.content?.workspace else { return [] }
            return workspace.screenGroups.map { group in
                PaletteTargetOption(id: group.id.rawValue, title: group.name.isEmpty ? ScreenStrings.untitledGroup : group.name,
                                    subtitle: workspace.displayName, symbol: "circle.fill")
            }
        case .workspace:
            let options = next.targets(of: kind)
            guard options.isEmpty else { return options }
            let shown = services.windows.active?.content?.workspace.id
            return services.machines.allWorkspaces.map(\.0).filter { $0.id != shown }.map { workspace in
                PaletteTargetOption(id: workspace.id, title: workspace.displayName, symbol: "rectangle.stack")
            }
        default:
            return next.targets(of: kind)
        }
    }
}
