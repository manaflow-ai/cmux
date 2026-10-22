import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextServer

/// Hosts the Machines section: follows the machine registry and each machine's last check, opens a
/// workspace on a machine through `workspace.newOnMachine` and Add Device through `device.add`.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let model = MachineSectionModel()
    private let machines: MachineRegistry
    private let health: MachineHealthStore
    private let list: MachineSectionListView
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        machines = services.machines
        health = services.machineHealth
        let registry = services.registry
        list = MachineSectionListView(newWorkspace: { id in
            registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string(id)]))
        }, addMachine: { registry.perform("device.add") })
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        list.translatesAutoresizingMaskIntoConstraints = false
        addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: topAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
        let machines = self.machines, health = self.health
        observation = Task { [weak self] in
            for await rows in ObservationStream({ MachineSectionModel.rows(machines, health: health) }) {
                self?.apply(rows)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    func refresh() {
        apply(MachineSectionModel.rows(machines, health: health))
    }

    private func apply(_ rows: [MachineSectionRow]) {
        model.update(rows)
        list.show(model.rows)
    }
}
