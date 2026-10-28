import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextServer

/// Hosts the Machines section (``MachineSectionView``, AppKit): follows the machine registry, each
/// machine's last check and the section's layout tunable, opens a workspace on a machine through
/// `workspace.newOnMachine` and Add Device through `device.add`.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let section: MachineSectionView
    private let machines: MachineRegistry
    private let health: MachineHealthStore
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        machines = services.machines
        health = services.machineHealth
        let registry = services.registry
        section = MachineSectionView(actions: MachineSectionView.Actions(newWorkspace: { id in
            registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string(id)]))
        }, addMachine: { registry.perform("device.add") }))
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        section.translatesAutoresizingMaskIntoConstraints = false
        addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
        let machines = self.machines, health = self.health
        observation = Task { [weak self] in
            for await (rows, style) in ObservationStream({
                (MachineSectionModel.rows(machines, health: health), ServerTunables.machinesStyle.value)
            }) {
                self?.section.update(rows, style: style)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
    }

    func refresh() {
        section.update(MachineSectionModel.rows(machines, health: health), style: ServerTunables.machinesStyle.value)
    }
}
