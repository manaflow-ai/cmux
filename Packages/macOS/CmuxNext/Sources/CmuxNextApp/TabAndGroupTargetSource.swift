import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSidebar

/// Palette target lists for tabs, tab groups and workspace groups, titled
/// as the strip and sidebar show them: a rename prompt (Rename Tab…,
/// Rename Tab Group…, Rename Group…) starts from the title listed here.
/// Other kinds fall through to `next`.
final class TabAndGroupTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        switch kind {
        case .tab:
            panes.flatMap(\.tabs).map { tab in
                PaletteTargetOption(id: tab.id, title: tab.displayTitle.isEmpty ? Strings.untitledTerminal : tab.displayTitle,
                                    symbol: tab.kind == .browser ? "globe" : "terminal")
            }
        case .tabGroup:
            panes.flatMap(\.tabGroups).map { group in
                PaletteTargetOption(id: group.id.rawValue, title: group.name, symbol: "circle.fill")
            }
        case .workspaceGroup:
            (services.windows.active?.sidebar.model.sections ?? []).flatMap(\.nodes).compactMap { node in
                guard case .group(let group) = node else { return nil }
                return PaletteTargetOption(id: group.id.rawValue, title: group.name, symbol: "folder")
            }
        default:
            next.targets(of: kind)
        }
    }

    /// Every pane on every machine.
    private var panes: [PaneModel] {
        services.machines.allWorkspaces.map(\.0).flatMap { $0.screens.flatMap(\.panes) }
    }
}
