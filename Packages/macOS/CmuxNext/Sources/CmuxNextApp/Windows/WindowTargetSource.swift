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
        switch kind {
        case .window: windows()
        case .workspace: workspaces()
        case .machine: machines()
        default: []
        }
    }

    /// Every workspace in the active window's sidebar order, the shown one
    /// last (Merge Workspace into…).
    private func workspaces() -> [PaletteTargetOption] {
        let shown = services.windows.active?.state.workspaceID
        let order = services.windows.active?.sidebar.model.allWorkspaces.map(\.id.rawValue) ?? []
        let listed = Set(order)
        let rest = services.machines.allWorkspaces.map(\.0.id).filter { !listed.contains($0) }
        let options = (order + rest).compactMap { id in
            services.workspace(id: id).map { PaletteTargetOption(id: id, title: $0.displayName, symbol: "rectangle.stack") }
        }
        return options.filter { $0.id != shown } + options.filter { $0.id == shown }
    }

    /// Connected machines: this Mac, then each Cloud machine (New Workspace on Machine…).
    private func machines() -> [PaletteTargetOption] {
        let machines = services.machines
        var options = [PaletteTargetOption(id: MachineRegistry.localID, title: WorkspaceVerbStrings.thisMac, symbol: "laptopcomputer")]
        for session in machines.cloud where session.daemon.connection != nil {
            options.append(PaletteTargetOption(id: session.machineID, title: session.machine.displayName ?? session.machineID, symbol: "cloud"))
        }
        return options
    }

    private func windows() -> [PaletteTargetOption] {
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
