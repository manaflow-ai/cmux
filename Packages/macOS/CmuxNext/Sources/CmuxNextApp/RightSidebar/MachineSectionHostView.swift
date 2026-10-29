import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextServer
import SwiftUI

/// Hosts the Machines section: follows the machine registry and each machine's last check, opens a
/// workspace on a machine through `workspace.newOnMachine` and Add Device through `device.add`. With
/// Labs `labs.machineJoin` on it also lists the machines that joined with a one-line token, read
/// when the section is made and each time it shows (never on a timer), with Check, Rotate and Revoke.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let model = MachineSectionModel()
    private let machines: MachineRegistry
    private let health: MachineHealthStore
    private let joined: JoinedMachineStore
    private var observation: Task<Void, Never>?
    /// The joined list's read in flight (a newer show replaces it).
    private var joinedRead: Task<Void, Never>?
    /// Reads the joined list again when Labs `labs.machineJoin` turns on or off (off empties it).
    private var switchWatch: Task<Void, Never>?

    init(services: AppServices) {
        machines = services.machines
        health = services.machineHealth
        joined = services.joinedMachines
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        let registry = services.registry
        let joined = self.joined
        let hosting = NSHostingView(rootView: MachineSectionListView(model: model, newWorkspace: { id in
            registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string(id)]))
        }, addMachine: { registry.perform("device.add") }, joinedStore: joined,
        joinedAction: { [weak services] action, machine, row in
            guard let services else { return }
            Self.perform(action, machine, rowID: row.id, services: services)
        }))
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
            for await rows in ObservationStream({ MachineSectionModel.rows(machines, health: health, joined: joined) }) {
                self?.model.update(rows)
            }
        }
        // task-owner: follows the switch for the section's life; deinit cancels it. Its first value
        // is the switch now, which the refresh above already read.
        switchWatch = Task { [weak services] in
            var last: Bool?
            // Any setting's change re-reads the snapshot: only a change of this switch reads the list.
            for await on in ObservationStream({ services?.settings?.snapshot.machineJoin == true }) {
                defer { last = on }
                guard let last, last != on else { continue }
                await joined.refresh()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
        joinedRead?.cancel()
        switchWatch?.cancel()
    }

    func refresh() {
        model.update(MachineSectionModel.rows(machines, health: health, joined: joined))
        let joined = self.joined
        joinedRead?.cancel()
        // task-owner: one list read per show; the next show or deinit cancels it.
        joinedRead = Task { await joined.refresh() }
    }

    /// A joined machine's menu item. Revoke asks first; Rotate and Revoke read the list again after.
    static func perform(_ action: JoinedMachineAction, _ machine: JoinedMachine, rowID: String, services: AppServices) {
        let window = services.windows.active?.window
        switch action {
        case .check:
            services.addMachine.checkJoined(id: machine.id, name: machine.name, rowID: rowID, over: window)
        case .rotate:
            // task-owner: one rotate; ends with its list read.
            Task { await services.joinedMachines.perform(.rotate, machine.id) }
        case .revoke:
            let prompt = DestructiveConfirmation.Prompt(title: JoinedMachineStrings.revokeTitle(machine.name),
                                                        body: JoinedMachineStrings.revokeBody, button: JoinedMachineStrings.revokeButton)
            DestructiveConfirmation.present(prompt, in: window, settings: services.settings) { confirmed in
                guard confirmed else { return }
                // task-owner: one revoke; ends with its list read.
                Task { await services.joinedMachines.perform(.revoke, machine.id) }
            }
        }
    }
}
