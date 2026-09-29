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
        let store = services.daemon.store
        let machine = { () -> SidebarMachine in
            let status: SidebarMachine.Status = switch store.connectionState {
            case .connected: .connected
            case .connecting, .disconnected: .connecting
            case .failed: .offline
            }
            return SidebarMachine(id: .local, name: Strings.localMachine, kind: .local, status: status)
        }
        observation = Task { [weak self] in
            for await sections in Observations({ SidebarMapping.sections(store.sidebarSections, machine: machine()) }) {
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

    func contextMenu(for target: SidebarContextTarget) -> NSMenu? {
        let registry = services.registry
        switch target {
        case .workspaces(let ids):
            guard let first = ids.first else { return nil }
            return registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: first.rawValue))
        case .group(let id):
            return registry.makeContextMenu(for: .workspaceGroup, target: ActionTargetRef(kind: .workspaceGroup, id: id.rawValue))
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
