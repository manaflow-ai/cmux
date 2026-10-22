import CmuxNextActions
import CmuxNextDesign
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

    /// A workspace's description (Edit Workspace Description… starts from it).
    func currentDescription(of target: ActionTargetRef) -> String? {
        guard target.kind == .workspace else { return nil }
        return services.workspace(id: target.id)?.workspaceDescription
    }

    /// Every workspace in the active window's sidebar order, the shown one
    /// last (Merge Workspace Into…).
    private func workspaces() -> [PaletteTargetOption] {
        let shown = services.windows.active?.state.workspaceID
        let order = services.windows.active?.sidebar.model.allWorkspaces.map(\.id.rawValue) ?? []
        let listed = Set(order)
        let rest = services.machines.allWorkspaces.map(\.0.id).filter { !listed.contains($0) }
        let options = (order + rest).compactMap { id in
            services.workspace(id: id).map { PaletteTargetOption(id: id, title: services.shownWorkspaceName($0), symbol: "rectangle.stack") }
        }
        return options.filter { $0.id != shown } + options.filter { $0.id == shown }
    }

    /// Connected machines: this Mac, then each Cloud machine (New Workspace on Machine…).
    private func machines() -> [PaletteTargetOption] {
        let machines = services.machines
        let local = Self.symbol(machines.icon(machine: MachineRegistry.localID), or: "laptopcomputer")
        var options = [PaletteTargetOption(id: MachineRegistry.localID, title: WorkspaceVerbStrings.thisMac, symbol: local)]
        for session in machines.cloud where session.daemon.connection != nil {
            options.append(PaletteTargetOption(id: session.machineID, title: session.machine.displayName ?? session.machineID,
                                               symbol: Self.symbol(machines.icon(machine: session.machineID), or: "cloud")))
        }
        return options
    }

    /// A machine's own icon (`session-icon-v1`) where it is an SF Symbol, else
    /// `fallback`, the machine's kind symbol (palette rows draw symbols only).
    private static func symbol(_ icon: String?, or fallback: String) -> String {
        if case .symbol(let name)? = IconValue(wire: icon) { return name }
        return fallback
    }

    private func windows() -> [PaletteTargetOption] {
        let windows = services.windows
        let active = windows.active?.state.id
        let options = windows.controllers.enumerated().map { index, controller in
            let name = controller.state.workspaceID.flatMap { services.workspace(id: $0).map(services.shownWorkspaceName) }
            let label = WindowStrings.windowNumber(index + 1)
            return PaletteTargetOption(id: controller.state.id, title: name ?? label, subtitle: name == nil ? nil : label,
                                       symbol: "macwindow")
        }
        return options.filter { $0.id != active } + options.filter { $0.id == active }
    }
}
