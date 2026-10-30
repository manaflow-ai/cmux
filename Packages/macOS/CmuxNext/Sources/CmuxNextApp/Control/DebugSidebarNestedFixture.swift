#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.sidebar_nested_fixture {scenario, window?}` (nested-groups prototype): the window's sidebar shows
/// a fixture tree of groups inside groups (`SidebarNestedFixture`) at the scenario's width, with its
/// rails and drag; `scenario: "off"` brings the live rows back. Answers the scenario and the rows drawn.
@MainActor
struct DebugSidebarNestedFixture {
    let services: AppServices

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        DebugSidebarNestedFixture(services: services).show(params)
    }

    func show(_ params: [String: JSONValue]) -> JSONValue {
        let name = params["scenario"]?.stringValue ?? "deep"
        guard let controller = services.windows.controllers.first(where: { c in params["window"]?.stringValue.map { $0 == c.state.id } ?? true })
                ?? services.windows.active else {
            return .object(["error": .string("no window")])
        }
        let sidebar = controller.sidebar
        if name == "off" {
            sidebar.container.showNestedFixture(nil)
            sidebar.rows.fixture = nil
            return .object(["scenario": .string("off")])
        }
        guard let scenario = SidebarNestedFixture.Scenario(rawValue: name) else {
            return .object(["error": .string("unknown scenario"),
                            "available": .array(SidebarNestedFixture.Scenario.allCases.map { .string($0.rawValue) })])
        }
        let fixture = SidebarNestedFixture(scenario: scenario)
        sidebar.restore(width: fixture.width, hidden: false)
        sidebar.model.filterText = ""
        sidebar.rows.fixture = fixture.sections
        // The needs-you scenario's who-started-whom, while the session tree is on (the feed's next pass replaces it).
        if !fixture.parents.isEmpty, var tree = SidebarSessionTree.shared.state {
            tree.parents.merge(fixture.parents) { _, fixture in fixture }
            SidebarSessionTree.shared.state = tree
        }
        sidebar.container.layoutSubtreeIfNeeded()
        sidebar.container.showNestedFixture(fixture)
        return .object(["scenario": .string(scenario.rawValue), "width": .number(fixture.width),
                        "window": .string(controller.state.id)])
    }
}

/// `debug.daemon_update {state?, id?, name?, ssh_host?, reason?, build?, notify?, sidebar?, tooltip?, window?}`
/// (DEBUG builds, captures of the daemon update): a capture host has no ssh peer and no update runs.
/// - `state` (`updating`, `retrying`, `updated`, `failed`, `rolled_back`, `cannot_update`, `cleared`): applies that
///   ``DaemonUpdateEvent`` to ``DaemonUpdateBoard/shared`` for the machine `id` (default
///   `ssh:build-box`), named `name` (`build-box`), on `ssh_host` (`build-box.example.com`); `reason`
///   for a failure (for `cannot_update`, the whole line), `build` for an update and the build a
///   failure is about (its notice stays closed for that build), `notify` as the policy sets it for
///   a recorded failure. A `cannot_update` machine has no toast; Settings > Updates lists it.
/// - `sidebar: true`: the window's sidebar shows a fixture This Mac and that ssh machine, a section each, whose
///   header tooltip is composed as a live connected one's (``SidebarBridge/sshTooltip(destination:session:detail:)``,
///   so whatever the live tooltip adds shows here too); `false` brings the live rows back. Shown again
///   after a `state`, it reads the board anew.
/// - `tooltip: true`: the synthetic pointer rests on that header (`debug.pointer_hover`), so its tooltip
///   opens after the usual delay; `false` moves the pointer away.
/// - `click: true`: the person's Update on that machine's line in Settings > Updates, as the board takes
///   it when the policy accepts it (no update runs): its line then says it is updating while its state is
///   `updating`.
extension DebugSidebarNestedFixture {
    static func daemonUpdate(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let id = params["id"]?.stringValue ?? "ssh:build-box"
        let name = params["name"]?.stringValue ?? "build-box"
        let host = params["ssh_host"]?.stringValue ?? "build-box.example.com"
        var answer: [String: JSONValue] = [:]
        if let raw = params["state"]?.stringValue {
            guard let state = state(raw, reason: params["reason"]?.stringValue ?? "the machine ran out of disk space",
                                    build: params["build"]?.stringValue ?? "abc123def") else {
                return .object(["error": .string("unknown state"),
                                "available": .array(["updating", "retrying", "updated", "failed", "rolled_back", "cannot_update", "cleared"]
                                    .map { .string($0) })])
            }
            DaemonUpdateBoard.shared.apply(DaemonUpdateEvent(id: id, displayName: name, sshHost: host, state: state,
                                                             notify: params["notify"]?.boolValue ?? false,
                                                             build: params["build"]?.stringValue))
            answer["state"] = .string(raw)
        }
        if params["click"]?.boolValue == true {
            // task-owner: one board call that returns at once (the stand-in policy accepts at once)
            Task { _ = await DaemonUpdateBoard.shared.update(id) { _ in true } }
            answer["click"] = .bool(true)
        }
        guard let controller = services.windows.controllers.first(where: { c in params["window"]?.stringValue.map { $0 == c.state.id } ?? true })
                ?? services.windows.active else {
            return .object(["error": .string("no window")])
        }
        let sidebar = controller.sidebar
        let machine = MachineID(id)
        if let show = params["sidebar"]?.boolValue {
            // A machine header (and its tooltip) is drawn only with a section per computer
            // (`sidebar.groupByComputer`). A render applies the design preferences to the model, so the
            // fixture turns the preference on; off, it goes back to the settings' value.
            DesignSettings.shared.sidebarSections.groupsByComputer = show
                || (services.settings?.snapshot.sidebarSections ?? .defaults).groupsByComputer
            sidebar.rows.fixture = show ? fixture(machine: machine, name: name, host: host) : nil
            sidebar.container.sidebarView.renderNow() // the list reloads on its next turn otherwise; the header is looked up below
            sidebar.container.layoutSubtreeIfNeeded()
            answer["sidebar"] = .bool(show)
        }
        if let hover = params["tooltip"]?.boolValue {
            let frame = hover ? sidebar.container.machineHeaderFrameInWindow(machine) : nil
            guard !hover || frame != nil else { return .object(["error": .string("the machine header is not drawn")]) }
            let point: JSONValue = frame.map { .array([.number($0.midX), .number($0.midY)]) } ?? .null
            var hoverParams: [String: JSONValue] = ["point": point]
            if let window = controller.window { hoverParams["window"] = .number(Double(window.windowNumber)) }
            answer["hover"] = DebugPointerHover.run(hoverParams, services: services)
        }
        return .object(answer)
    }

    static func state(_ raw: String, reason: String, build: String) -> DaemonUpdateEvent.State? {
        switch raw {
        case "updating": .updating
        case "retrying": .retrying
        case "updated": .updated(build: build)
        case "failed": .failed(reason: reason, rolledBack: false)
        case "rolled_back": .failed(reason: reason, rolledBack: true)
        case "cannot_update": .cannotUpdate(reason: reason)
        case "cleared": .cleared
        default: nil
        }
    }

    /// This Mac with one workspace, then the ssh machine with one, so its header shows (one machine's
    /// header titles the list instead and has no tooltip).
    private static func fixture(machine: MachineID, name: String, host: String) -> [SidebarSection] {
        let destination = (try? SSHDestination(parsing: "dev@" + host)) ?? (try? SSHDestination(parsing: "build-box"))
        let tooltip = destination.map { SidebarBridge.sshTooltip(destination: $0, session: RemoteSessionName.defaultName, detail: nil) }
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ssh = SidebarMachine(id: machine, name: name, kind: .ssh, status: .connected, detail: tooltip)
        return [
            SidebarSection(kind: .machine(local), nodes: [.workspace(workspace("w-local", "cmux", on: .local))]),
            SidebarSection(kind: .machine(ssh), nodes: [.workspace(workspace("w-remote", "server", on: machine))]),
        ]
    }

    private static func workspace(_ id: String, _ title: String, on machine: MachineID) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: title)
    }
}
#endif
