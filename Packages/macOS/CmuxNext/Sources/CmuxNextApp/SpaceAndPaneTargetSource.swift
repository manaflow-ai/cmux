import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette

/// Palette and menu target lists for spaces (New Workspace in Space…, Move
/// Workspace to Space ▸) in the strip's order, and for panes (Swap With
/// Session…): every pane of the active machine, the focused pane last so
/// another pane is the first choice. Other kinds fall through to `next`.
final class SpaceAndPaneTargetSource: PaletteTargetSource {
    private weak var services: AppServices?
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        guard let services else { return [] }
        switch kind {
        case .profile:
            return spaces.map { PaletteTargetOption(id: $0.id.rawValue, title: $0.name.isEmpty ? $0.id.rawValue : $0.name, symbol: "circle.fill") }
        case .pane:
            let focused = services.windows.active?.focusedPane?.paneKey
            let options = services.activeDaemon.store.workspaces.flatMap { workspace in
                workspace.screens.flatMap(\.panes).map { pane in
                    let shown = pane.tabs.indices.contains(pane.defaultTabIndex) ? pane.tabs[pane.defaultTabIndex].displayTitle : ""
                    let title = [pane.name ?? "", shown].first { !$0.isEmpty } ?? Strings.untitledTerminal
                    // `kind:id`, as a pane's own id may hold a colon (`pane:3`).
                    return PaletteTargetOption(id: ActionTargetRef(kind: .pane, id: pane.id).description, title: title,
                                               subtitle: workspace.displayName, symbol: "rectangle.split.2x1")
                }
            }
            let last = focused.map { ActionTargetRef(kind: .pane, id: $0).description }
            return options.filter { $0.id != last } + options.filter { $0.id == last }
        default:
            return next.targets(of: kind)
        }
    }

    /// A space's or pane's own name; nil for an unnamed pane.
    func title(of target: ActionTargetRef) -> String? {
        switch target.kind {
        case .profile: spaces.first { $0.id.rawValue == target.id }?.name
        case .pane: services?.activeDaemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).first { $0.id == target.id }?.name.flatMap { $0.isEmpty ? nil : $0 }
        default: next.title(of: target)
        }
    }

    /// The local daemon's spaces in the strip's order.
    private var spaces: [ProfileModel] {
        (services?.machines.local.store.profiles ?? []).sorted { $0.index < $1.index }
    }

    /// Descriptions belong to kinds `next` lists.
    func currentDescription(of target: ActionTargetRef) -> String? {
        next.currentDescription(of: target)
    }
}
