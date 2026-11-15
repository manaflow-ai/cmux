import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextServer

/// Hosts the Machines section (no surface shows it now: the right sidebar that held it is gone; a React page, `MachineSectionPageProvider.makeSection`), made the first
/// time the section shows: its provider reads the machine registry, each machine's last check, the
/// section's layout tunable and the person's machines joined through the hub (`cmux machine list`),
/// read when the section is made and each time it shows. New Workspace and Add Machine… run
/// `workspace.newOnMachine` and `device.add`; a row's menus are the registry's native ones.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let section: NSView  // a PageSectionHost; its page routes hold the provider
    private let joined: JoinedMachineStore
    /// The joined list's read in flight (a newer show replaces it).
    private var joinedRead: Task<Void, Never>?

    init(services: AppServices) {
        let machines = services.machines, health = services.machineHealth, joined = services.joinedMachines, registry = services.registry
        self.joined = joined
        let provider = MachineSectionPageProvider(dependencies: .init(
            rows: { MachineSectionRow.rows(machines, health: health, joined: joined) },
            style: { ServerTunables.machinesStyle.value }, joined: { joined },
            newWorkspace: { registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string($0)])) },
            addMachine: { registry.perform("device.add") }, present: { _, _ in },
            menu: { kind, row in Self.menu(kind, row: row, registry: registry) }, cloudTeam: { [weak cloud = services.cloud] in cloud.flatMap { TeamRowText.machinesTeam($0.auth) } }))
        section = provider.makeSection(joined: joined)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        section.translatesAutoresizingMaskIntoConstraints = false
        addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        joinedRead?.cancel()
    }

    func refresh() {
        let joined = self.joined
        joinedRead?.cancel()
        // task-owner: one list read per show; the next show or deinit cancels it.
        joinedRead = Task { await joined.refresh() }
    }

    /// A row's native menu: New Workspace on This Machine (`row`, disabled while the link is down), or a
    /// joined machine's Check, Rotate Credential and Revoke… (`joined`), run on the row it opened on.
    static func menu(_ kind: String, row: MachineSectionRow, registry: ActionRegistry) -> NSMenu? {
        if kind == "joined", let machine = row.joined { return joinedMenu(machine, rowID: row.id, registry: registry) }
        guard kind == "row", let item = registry.makeContextMenuItem(for: "workspace.newOnMachine", in: .machineSection,
                                                                     arguments: ["machine": .string(row.id)]) else { return nil }
        item.title = MachineSectionRow.newWorkspaceTitle
        item.isEnabled = row.isConnected
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        return menu
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
                          labsOn: { true },
                          perform: { [weak services] action, machine, rowID in
                              guard let services else { return }
                              Self.perform(action, machine, rowID: rowID, services: services)
                          })
    }

    /// Binds Check, Rotate Credential and Revoke… on a joined machine (a `machine:` target that is a
    /// joined machine's id). They do nothing while `labsOn` says no (the app's is always on). A revoked
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
