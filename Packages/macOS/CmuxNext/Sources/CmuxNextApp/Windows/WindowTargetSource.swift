import CmuxNextActions
import CmuxNextPalette

/// Lists windows for `window` target arguments (Move Workspace to Window…
/// from the palette, a menu, or a right-click): each titled by the
/// workspace it shows, the active window last so another window is the
/// first choice.
final class WindowTargetSource: PaletteTargetSource {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        guard kind == .window else { return [] }
        let windows = services.windows!
        let active = windows.active?.state.id
        let options = windows.controllers.enumerated().map { index, controller in
            let name = controller.state.workspaceID.flatMap { services.workspace(id: $0)?.displayName }
            let label = WindowStrings.windowNumber(index + 1)
            return PaletteTargetOption(id: controller.state.id, title: name ?? label, subtitle: name == nil ? nil : label,
                                       symbol: "macwindow")
        }
        return options.filter { $0.id != active } + options.filter { $0.id == active }
    }
}
