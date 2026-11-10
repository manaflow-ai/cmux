import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPalette
import CmuxNextServer

/// Hosts the right sidebar's Machines section (a React page, `MachineSectionPageProvider.makeSection`), made the first
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
        if kind == "joined", let machine = row.joined { return JoinedMachineAction.menu(machine, rowID: row.id, registry: registry) }
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

    /// The palette's pick for Rotate and Revoke: each joined machine not revoked, by name.
    static func joinedOptions(_ machines: [JoinedMachine]) -> [PaletteTargetOption] {
        machines.filter { $0.state != .revoked }.map { PaletteTargetOption(id: $0.id, title: $0.name, subtitle: $0.hostname, symbol: "server.rack") }
    }

    static func bindJoinedActions(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        JoinedMachineAction.bind(into: registry, store: { [weak services] in services?.joinedMachines }, labsOn: { true },
                                 unknown: RemoteStrings.unknownMachine,
                                 perform: { [weak services] action, machine, rowID in
                                     guard let services else { return }
                                     Self.perform(action, machine, rowID: rowID, services: services)
                                 })
    }
}
