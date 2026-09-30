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
        // Synchronous, before the hide animation starts: focus leaves the
        // sidebar in the same turn (plans/cmux-next/focus.md).
        model.onPresentationChange = { [weak state] presentation in
            state?.focus.send(.sidebarVisibility(hidden: presentation == .hidden))
        }
        container.sidebarView.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        // Return or Escape in the inline rename field gives the keyboard
        // back to the focused content (plans/cmux-next/focus.md R8).
        container.sidebarView.onRenameEnded = { [weak state] byKeyboard in
            guard byKeyboard, let focus = state?.focus else { return }
            focus.send(.focusTarget(.content, source: .keyboard))
        }
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
        let registry = services.windows.registry
        let windowState = state
        observation = Task { [weak self] in
            // `state.id` is read inside: the launch window adopts a saved id.
            for await sections in Observations({ Self.sections(machines, statuses: board, members: registry.members(of: windowState.id)) }) {
                guard let self, self.model.sections != sections else { continue }
                self.model.sections = sections
            }
        }
        let state = state
        let model = model
        widthObservation = Task { [weak self] in
            for await (width, presentation) in Observations({ (model.width, model.presentation) }) {
                guard let self else { return }
                state.sidebarWidth = Double(width)
                state.sidebarHidden = presentation == .hidden
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

    /// This window's sidebar: every machine section, listing only the
    /// workspaces the window owns (`WindowRegistry`).
    static func sections(_ machines: MachineRegistry, statuses: WorkspaceStatusBoard, members: [String]) -> [SidebarRowSection] {
        SidebarMembership.filter(sections(machines, statuses: statuses), members: Set(members))
    }

    /// One section per machine: the local daemon, then each Cloud machine
    /// (empty while it connects), with every workspace.
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

    /// Applies saved state without animating.
    func restore(width: Double?, hidden: Bool) {
        container.restore(width: width.map { CGFloat($0) }, presentation: hidden ? .hidden : .shown)
    }
}
