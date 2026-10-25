import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextServer
import SwiftUI

/// Hosts the Machines section: follows the machine registry and each machine's last check, opens a
/// workspace on a machine through `workspace.newOnMachine` and Add Device through `device.add`.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let model = MachineSectionModel()
    private let machines: MachineRegistry
    private let health: MachineHealthStore
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        machines = services.machines
        health = services.machineHealth
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        let registry = services.registry
        let hosting = NSHostingView(rootView: MachineSectionListView(model: model, newWorkspace: { id in
            registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string(id)]))
        }, addMachine: { registry.perform("device.add") }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
        let machines = self.machines, health = self.health
        observation = Task { [weak self] in
            for await rows in ObservationStream({ MachineSectionModel.rows(machines, health: health) }) {
                self?.model.update(rows)
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
        model.update(MachineSectionModel.rows(machines, health: health))
    }
}
