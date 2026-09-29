import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import Observation

/// Feeds one window's sidebar from the daemon store and turns sidebar
/// intents into daemon commands (SidebarBridge+Intents). Selection is
/// client-local: it only changes which workspace this window shows.
final class SidebarBridge {
    let model = SidebarModel()
    let container: SidebarContainerView
    unowned let services: AppServices
    unowned let state: WindowState
    private var observation: Task<Void, Never>?
    private var selectionObservation: Task<Void, Never>?
    private var widthObservation: Task<Void, Never>?

    init(services: AppServices, state: WindowState) {
        self.services = services
        self.state = state
        container = SidebarContainerView(model: model)
        model.onIntent = { [weak self] intent in self?.handle(intent) }
        container.sidebarView.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        observe()
    }

    func teardown() {
        observation?.cancel()
        selectionObservation?.cancel()
        widthObservation?.cancel()
    }

    private func observe() {
        let machines = services.machines
        let board = services.statusBoard
        observation = Task { [weak self] in
            for await sections in Observations({ Self.sections(machines, statuses: board) }) {
                self?.model.sections = sections
            }
        }
        let state = state
        let model = model
        widthObservation = Task { [weak self] in
            for await _ in Observations({ (model.width, model.presentation) }) {
                guard let self else { return }
                self.services.windows.stateDidChange(state)
            }
        }
        selectionObservation = Task { [weak self] in
            for await id in Observations({ state.workspaceID }) {
                guard let self else { return }
                let selected = id.map { SidebarWorkspaceID($0) }
                if self.model.activeWorkspaceID != selected {
                    self.model.activeWorkspaceID = selected
                    self.model.selection = selected.map { [$0] } ?? []
                }
            }
        }
    }

    /// One section per machine: the local daemon, then each Cloud machine
    /// (empty while it connects).
    static func sections(_ machines: MachineRegistry, statuses: WorkspaceStatusBoard) -> [SidebarRowSection] {
        let status = { (id: String) in statuses.line(for: id) }
        var sections = SidebarMapping.sections(machines.local.store.sidebarSections,
                                               machine: machine(for: machines.local, name: Strings.localMachine, kind: .local),
                                               statusLine: status)
        for session in machines.cloud {
            let header = machine(for: session.daemon, name: session.machine.title, kind: .cloud, live: session.machine.status.isLive)
            sections += SidebarMapping.sections(session.daemon.store.sidebarSections, machine: header, statusLine: status)
        }
        return sections
    }

    static func machine(for daemon: DaemonService, name: String, kind: SidebarMachine.Kind, live: Bool = true) -> SidebarMachine {
        let status: SidebarMachine.Status = switch daemon.store.connectionState {
        case .connected: .connected
        case .connecting, .disconnected: live ? .connecting : .offline
        case .failed: live ? .connecting : .offline
        }
        return SidebarMachine(id: MachineID(daemon.machineID), name: name, kind: kind, status: status)
    }

    func contextMenu(for target: SidebarContextTarget) -> NSMenu? {
        let registry = services.registry
        switch target {
        case .workspaces(let ids):
            guard let first = ids.first else { return nil }
            return registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: first.rawValue))
        case .group(let id):
            return registry.makeContextMenu(for: .workspaceGroup, target: ActionTargetRef(kind: .workspaceGroup, id: id.rawValue))
        case .section(.machine(let machine)) where machine.rawValue != MachineRegistry.localID:
            return registry.makeContextMenu(for: .cloudMachine, target: ActionTargetRef(kind: .machine, id: machine.rawValue))
        case .section, .background:
            return registry.makeContextMenu(for: .sidebarBackground)
        }
    }

    // MARK: Persistence mirror

    var record: (width: Double, collapsed: Bool) {
        (Double(model.width), model.presentation != .expanded)
    }

    func restore(width: Double?, collapsed: Bool) {
        if let width { model.width = CGFloat(width) }
        model.presentation = collapsed ? .iconsOnly : .expanded
    }
}
