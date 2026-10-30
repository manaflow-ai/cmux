import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextServer

/// Hosts the Machines section (``MachineSectionView``, AppKit): follows the machine registry, each
/// machine's last check and the section's layout tunable, opens a workspace on a machine through
/// `workspace.newOnMachine` and Add Device through `device.add`. With Labs `labs.machineJoin` on it
/// also lists the machines that joined with a one-line token, read when the section is made and each
/// time it shows (never on a timer), with Check, Rotate and Revoke.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let section: MachineSectionView
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
        let registry = services.registry
        section = MachineSectionView(actions: MachineSectionView.Actions(newWorkspace: { id in
            registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string(id)]))
        }, addMachine: { registry.perform("device.add") }, newWorkspaceMenuItem: { id in
            registry.makeContextMenuItem(for: "workspace.newOnMachine", in: .machineSection, arguments: ["machine": .string(id)])
        }, joinedMenu: { machine, row in Self.joinedMenu(machine, rowID: row.id, registry: registry) }))
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
        let machines = self.machines, health = self.health, joined = self.joined
        observation = Task { [weak self] in
            for await (rows, style, state) in ObservationStream({
                (MachineSectionRow.rows(machines, health: health, joined: joined), ServerTunables.machinesStyle.value,
                 MachineSectionView.JoinedRowState(joined))
            }) {
                self?.section.update(rows, style: style, joined: state)
            }
        }
        // task-owner: follows the switch for the section's life; deinit cancels it. Its first value
        // is the switch now, which the refresh above already read.
        switchWatch = Task { [weak self, weak services] in
            var last: Bool?
            // Any setting's change re-reads the snapshot: only a change of this switch reads the list.
            // The read runs beside the watch, never awaited by it, so a later flip is seen at once:
            // turning the switch off empties the rows and drops any read still in flight.
            for await on in ObservationStream({ services?.settings?.snapshot.machineJoin == true }) {
                defer { last = on }
                guard let last, last != on else { continue }
                self?.refresh()
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
        section.update(MachineSectionRow.rows(machines, health: health, joined: joined), style: ServerTunables.machinesStyle.value,
                       joined: MachineSectionView.JoinedRowState(joined))
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
            let asked = JoinedMachineAction.revokePrompt(machine.name)
            let prompt = DestructiveConfirmation.Prompt(title: asked.title, body: asked.body, button: asked.button)
            DestructiveConfirmation.present(prompt, in: window, settings: services.settings) { confirmed in
                guard confirmed else { return }
                // task-owner: one revoke; ends with its list read.
                Task { await services.joinedMachines.perform(.revoke, machine.id) }
            }
        }
    }

    /// The registered action of a joined machine's menu row (`JoinedMachineActionCatalog`).
    static func actionID(_ action: JoinedMachineAction) -> ActionID { ActionID(rawValue: "machine.joined.\(action.rawValue)") }

    /// A joined machine's "…" menu: the registry's rows for it, run on its id with the row it opened
    /// on (`row`, where Check records its result).
    static func joinedMenu(_ machine: JoinedMachine, rowID: String, registry: ActionRegistry) -> NSMenu {
        registry.makeContextMenu(for: .joinedMachine, target: ActionTargetRef(kind: .machine, id: machine.id),
                                 arguments: ["row": .string(rowID)])
    }

    static func bindJoinedActions(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        bindJoinedActions(into: registry, store: { [weak services] in services?.joinedMachines },
                          labsOn: { [weak services] in services?.settings?.snapshot.machineJoin == true },
                          perform: { [weak services] action, machine, rowID in
                              guard let services else { return }
                              Self.perform(action, machine, rowID: rowID, services: services)
                          })
    }

    /// Binds Check, Rotate Credential and Revoke… on a joined machine (a `machine:` target that is a
    /// joined machine's id). They do nothing while Labs `labs.machineJoin` is off. A revoked
    /// machine's menu leaves out Rotate and Revoke; while a change runs on it they wait.
    static func bindJoinedActions(into registry: ActionRegistry, store: @escaping @MainActor () -> JoinedMachineStore?,
                                  labsOn: @escaping @MainActor () -> Bool,
                                  perform: @escaping @MainActor (JoinedMachineAction, JoinedMachine, String) -> Void) {
        let joined: @MainActor (ActionInvocation) -> JoinedMachine? = { invocation in
            guard let id = invocation.target?.id else { return nil }
            return store()?.machines.first { $0.id == id }
        }
        for action in JoinedMachineAction.allCases {
            let id = actionID(action)
            // Check opens its checklist and Revoke its question on this turn; Rotate starts at once.
            // The platform's answers come later, through the store (the row's spinner and caption).
            registry.bindEffect(id, unavailable: { labsOn() ? nil : JoinedMachineAction.labsOff }, effect: { invocation in
                guard let machine = joined(invocation) else {
                    return .refused(RemoteStrings.unknownMachine(invocation.target?.id ?? ""))
                }
                perform(action, machine, invocation["row"]?.stringValue ?? JoinedMachine.healthID(machine.id))
                return .done
            })
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                guard let machine = joined(invocation) else { return true }
                return !action.isAvailable(for: machine.state)
            }
            guard action != .check else { continue }
            ActionTargetReasons.set(id, in: registry) { invocation in
                guard let machine = joined(invocation), store()?.busy.contains(machine.id) == true else { return nil }
                return JoinedMachineAction.busy
            }
        }
    }
}
