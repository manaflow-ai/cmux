import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCloud
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextSettingsWindow
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Machines carry an icon (`session-icon-v1`, cx-qno.11.4), the shared icon string: an emoji, an
/// SF Symbol name or a stored image or SVG asset of the home daemon. The home daemon's session
/// registry keeps it on each machine's session record (`list-personal`), keyed by the session id
/// `SessionRegistrar` records each machine under (its daemon's `registry_id`; this Mac's own row
/// too). The sidebar header, a remote workspace's hover card, the machine picker and the Settings
/// machine rows draw it in place of the machine's symbol (the symbol stands in while a stored asset
/// loads), and Set/Remove Machine Icon are machine actions on every machine header's menu.
@MainActor @Suite(.serialized)
struct MachineIconTests {
    static let asset = "svg:sha256-" + String(repeating: "f", count: 64)
    static let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="#22d"></path></svg>"##.utf8)

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// This Mac's daemon as `session`, recorded in its own session registry (as `record` with `icon`).
    static func record(_ services: AppServices, session: String = "s-local", record: String = "s-local", icon: String?) {
        var tree = DaemonTree(registryID: session)
        tree.personal = PersonalState(sessions: [
            SessionRecord(id: record, transport: .object(["kind": .string("local")]), migrated: true, icon: icon),
        ])
        services.machines.local.store.apply(snapshot: tree)
    }

    /// A Cloud machine `id` this run has not loaded (stopped, or its link has not answered).
    static func cloudMachine(_ services: AppServices, id: String) -> CloudMachineSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-machine-icon-\(UUID().uuidString.prefix(8))")
        let paths = CloudPaths(root: root), binary = URL(fileURLWithPath: "/usr/bin/false"), api = services.cloud.api
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "cn-icon-test")
        let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "cn-icon-test")
        let session = CloudMachineSession(machine: CloudMachine(id: id, displayName: "Icon VM"), link: link,
                                          mainWork: services.mainWork)
        services.machines.add(session)
        return session
    }

    /// This Mac's sidebar header.
    static func header(_ services: AppServices) -> SidebarMachine? {
        SidebarBridge.sections(services.machines, profile: .defaultProfile).lazy.compactMap(\.machine).first { $0.kind == .local }
    }

    static func favicon() throws -> SidebarFavicon {
        SidebarFavicon(try #require(IconAssetImages.decode(svg, mediaType: "image/svg+xml")))
    }

    // MARK: The session record and the request

    @Test func aSessionRecordCarriesItsIconAndOlderDaemonsSendNone() throws {
        func decoded(_ json: String) throws -> SessionRecord {
            try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        }
        #expect(try decoded(#"{"session_id":"s1","transport":{"kind":"local"},"icon":"🚀"}"#).icon == "🚀")
        #expect(try decoded(#"{"session_id":"s1","icon":null}"#).icon == nil)
        #expect(try decoded(#"{"session_id":"s1"}"#).icon == nil, "an older daemon sends no icon")
        let state = try JSONDecoder().decode(PersonalState.self, from: Data(
            #"{"personal_revision":3,"sessions":[{"session_id":"s1","icon":"\#(Self.asset)"}]}"#.utf8))
        #expect(state.sessions.first?.icon == Self.asset)
    }

    /// `set-session-icon` always sends `icon`: a string sets it, null clears it. Only the home
    /// daemon keeps the registry, so a remote machine without the capability is not "limited".
    @Test func setSessionIconAlwaysSendsTheIconAndNullClearsIt() throws {
        func sent(_ icon: String?) throws -> [String: Any] {
            let data = try JSONEncoder().encode(SetSessionIconRequest(sessionID: "s1", icon: icon))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try sent("🚀")["icon"] as? String == "🚀")
        #expect(try sent("🚀")["session_id"] as? String == "s1")
        #expect(try sent(nil)["icon"] is NSNull, "a clear sends null, never leaves the key out")
        #expect(SetSessionIconRequest.command == "set-session-icon")
        #expect(SetSessionIconRequest.requiredCapability == "session-icon-v1")
        #expect(DaemonCapability.optional.contains("session-icon-v1"))
        #expect(DaemonCapability.homeOnly.contains("session-icon-v1"))
    }

    // MARK: The sidebar header

    /// This Mac's header reads its own row of the home registry (the session its daemon's
    /// `registry_id` names), the row `SessionRegistrar` records for it.
    @Test func thisMacsHeaderTakesTheIconOfItsSessionRecord() {
        let services = Self.services()
        Self.record(services, icon: "🚀")
        #expect(Self.header(services)?.icon == .emoji("🚀"))
        Self.record(services, icon: "star.fill")
        #expect(Self.header(services)?.icon == .symbol("star.fill"))
        Self.record(services, icon: nil)
        #expect(Self.header(services)?.icon == nil, "no icon: the header draws as before")
        Self.record(services, record: "s-other", icon: "🚀")
        #expect(Self.header(services)?.icon == nil, "another session's icon is not this Mac's")
    }

    @Test func aStoredIconDrawsOnceReadAndTheMachineSymbolUntilThen() throws {
        let favicon = try Self.favicon()
        #expect(SidebarMapping.machineIcon(Self.asset, asset: { $0 == Self.asset ? favicon : nil }) == .favicon(favicon))
        #expect(SidebarMapping.machineIcon(Self.asset) == nil, "the machine symbol stands in while the asset loads")
        #expect(SidebarMapping.machineIcon("Not An Icon") == nil)
        #expect(SidebarMapping.machineIcon(nil) == nil)
    }

    /// The header draws a set icon before the name and nothing extra without one; the lone
    /// machine's "Projects" header is the list's title, not the machine's, and draws none.
    @Test func theSectionHeaderDrawsTheIconOnlyWhenTheMachineHasOne() {
        func header(_ icon: WorkspaceIcon?, titlesProjects: Bool = false) -> SectionHeaderRowView {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local, icon: icon)
            let section = SidebarSection(kind: .machine(machine), nodes: [])
            let row = SidebarRow(key: .section(section.id), y: 0, height: 28, section: section.id, group: nil, siblingIndex: 0,
                                 parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                                 titlesProjects: titlesProjects)
            let view = SectionHeaderRowView(key: row.key)
            view.configure(section, row: row)
            return view
        }
        #expect(header(.emoji("🚀")).showsMachineIcon)
        #expect(header(.symbol("star.fill")).showsMachineIcon)
        #expect(!header(nil).showsMachineIcon)
        #expect(!header(.emoji("🚀"), titlesProjects: true).showsMachineIcon)
    }

    // MARK: Hover card, picker and Settings

    @Test func aRemoteWorkspacesHoverCardShowsItsMachinesIcon() throws {
        let workspace = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("w1"), machineID: CmuxNextSidebar.MachineID("vm-1"), title: "build")
        func host(_ icon: WorkspaceIcon?) throws -> WorkspaceHoverCardContent.Fact {
            let machine = SidebarMachine(id: CmuxNextSidebar.MachineID("vm-1"), name: "cloud-a1", kind: .cloud, icon: icon)
            return try #require(WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date()).facts.first { $0.text == "cloud-a1" })
        }
        #expect(try host(.emoji("🚀")).mark == "🚀")
        #expect(try host(.symbol("star.fill")).mark == "star.fill")
        let favicon = try Self.favicon()
        #expect(try host(.favicon(favicon)).image == favicon)
        let plain = try host(nil)
        #expect(plain.mark == nil && plain.image == nil, "no icon: the cloud symbol")
    }

    @Test func theMachinePickerDrawsAMachinesSymbolIcon() {
        let services = Self.services()
        let source = WindowTargetSource(services: services)
        #expect(source.targets(of: .machine).first { $0.id == MachineRegistry.localID }?.symbol == "laptopcomputer")
        Self.record(services, icon: "star.fill")
        #expect(source.targets(of: .machine).first { $0.id == MachineRegistry.localID }?.symbol == "star.fill")
    }

    /// The Settings machine rows send the machine's icon (the page draws an emoji or a stored
    /// asset in the row's mark), else the machine's symbol.
    @Test func aSettingsMachineRowSendsItsIcon() {
        #expect(SettingsListRow.machine(id: "vm-1", title: "cloud-a1", icon: "🚀", symbol: "cloud").icon == .emoji("🚀"))
        #expect(SettingsListRow.machine(id: "vm-1", title: "cloud-a1", icon: Self.asset, symbol: "cloud").icon.wire == Self.asset)
        #expect(SettingsListRow.machine(id: "vm-1", title: "cloud-a1", icon: nil, symbol: "cloud").icon == .symbol("cloud"))
    }

    // MARK: Actions

    @Test func setAndRemoveMachineIconAreMachineActions() throws {
        for (id, cli) in [("machine.setIcon", "machine set-icon"), ("machine.clearIcon", "machine clear-icon")] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id }, "\(id) is in the catalog")
            #expect(descriptor.targets == [.machine])
            #expect(descriptor.cliName == cli)
        }
        let set = try #require(ActionCatalog.all.first { $0.id.rawValue == "machine.setIcon" })
        #expect(set.arguments.contains { $0.name == "icon" }, "the CLI and MCP name the icon")
        // Icon rows (identity), then Reconnect (connection), then Remove Remote Group, which
        // ungroups the host's rows (close: "Close, delete, forget, ungroup").
        #expect(ContextMenuCatalog.shared.entries(for: .machineSection)
            == [.folder(.appearance, [.action("machine.setIcon"), .action("machine.clearIcon")]),
                .separator, .action("machine.reconnect"), .separator, .action("remote.removeGroup")])
    }

    /// Every machine header's right-click menu offers Set Icon, aimed at that machine, beside its
    /// own rows (This Mac keeps the sidebar's rows) and within the 12-row top level (the
    /// sidebar's menu is full, so This Mac's goes in a folder); Remove Icon shows only while the
    /// machine has an icon.
    @Test func thisMacsHeaderMenuOffersItsIconWithinTheTopLevelLimit() throws {
        let services = Self.services()
        AppActions.bind(services)
        func allItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
            items.flatMap { item in [item] + (item.submenu.map { allItems($0.items) } ?? []) }
        }
        func iconRuns() throws -> [(id: ActionID, target: ActionTargetRef?)] {
            let menu = SidebarContextMenus.machineMenu(MachineRegistry.localID, services: services)
            let background = services.registry.makeContextMenu(for: .sidebarBackground)
            #expect(menu.items.filter { !$0.isSeparatorItem }.count <= 12, "a menu keeps at most 12 top-level rows")
            #expect(menu.items.filter { !$0.isSeparatorItem }.count >= background.items.filter { !$0.isSeparatorItem }.count,
                    "the sidebar's own rows stay")
            return allItems(menu.items).compactMap { ActionRegistry.menuRun(of: $0) }
                .filter { $0.id.rawValue.hasPrefix("machine.") && $0.id.rawValue.hasSuffix("Icon") }.map { (id: $0.id, target: $0.target) }
        }
        Self.record(services, icon: nil)
        let plain = try iconRuns()
        #expect(plain.map(\.id) == ["machine.setIcon"])
        #expect(plain.first?.target == ActionTargetRef(kind: .machine, id: MachineRegistry.localID))
        Self.record(services, icon: "🚀")
        #expect(try iconRuns().map(\.id) == ["machine.setIcon", "machine.clearIcon"])
    }

    /// Machine icons live in the home daemon's session registry: without `session-icon-v1` there
    /// (an older daemon, or none yet) the actions say why instead of doing nothing.
    @Test func machineIconActionsWaitForAHomeDaemonThatServesThem() {
        let services = Self.services()
        AppActions.bind(services)
        for id: ActionID in ["machine.setIcon", "machine.clearIcon"] {
            #expect(services.registry.unavailableReason(for: id) != nil, "\(id) runs without session-icon-v1")
        }
    }

    // MARK: Before a machine loads

    /// A machine whose daemon has not loaded this run (an SSH host that is down, a stopped Cloud
    /// machine, an unreachable server) has no `registry_id` yet, but the home registry still holds
    /// its record: the record whose `transport` names it, read back the way the services that
    /// restore it read it. Its header draws that record's icon and Set/Remove aim at it.
    @Test func aMachineThatHasNotLoadedTakesItsIconFromItsHomeRegistryRecord() throws {
        let services = Self.services()
        _ = Self.cloudMachine(services, id: "vm-icon1")
        let ssh = try SSHHost(destination: SSHDestination(parsing: "me@box"))
        let route = try #require(ServerReach.brainRoute(serverName: "mini"))
        let server = try ServerReach(hostID: "host_abcdef12", installID: "inst_abcdef12", name: "mini", route: route)
        func transport(_ fields: [String: String]) -> JSONValue { .object(fields.mapValues(JSONValue.string)) }
        var tree = DaemonTree(registryID: "s-local")
        tree.personal = PersonalState(sessions: [
            SessionRecord(id: "s-local", transport: transport(["kind": "local"]), migrated: true),
            SessionRecord(id: "s-vm", transport: transport(["kind": "cloud", "machine": "vm-icon1"]), migrated: true, icon: "🚀"),
            SessionRecord(id: "s-ssh", transport: transport(ssh.transportFields.merging(["connect": "false"]) { $1 }), migrated: true,
                          icon: "star.fill"),
            SessionRecord(id: "s-server", transport: transport(server.transportFields), migrated: true, icon: "🦊"),
        ])
        services.machines.local.store.apply(snapshot: tree)

        let header = SidebarBridge.sections(services.machines, profile: .defaultProfile).lazy.compactMap(\.machine)
            .first { $0.id.rawValue == "vm-icon1" }
        #expect(header?.icon == .emoji("🚀"), "the stopped Cloud machine's header draws its record's icon")
        #expect(services.machines.icon(machine: ssh.machineID) == "star.fill", "an SSH machine, by its route")
        #expect(services.machines.icon(machine: server.machineID) == "🦊", "a paired server, by its host")
        #expect(services.machines.icon(machine: "vm-other") == nil, "another machine's record is not this one's")

        let target = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-icon1"))
        #expect(try MachineIconHandlers.machineID(target, services) == "vm-icon1", "Set/Remove aim at the recorded machine")
    }

    /// Until `SessionRegistrar`'s `put-session` lands, the machine has a `registry_id` but no home
    /// record, and `set-session-icon` would answer `unknown session` after the undo was offered:
    /// the actions refuse first.
    @Test func machineIconActionsRefuseUntilTheHomeRegistryRecordsTheMachine() {
        let services = Self.services()
        Self.record(services, session: "s-local", record: "s-other", icon: nil)
        let target = ActionInvocation(target: ActionTargetRef(kind: .machine, id: MachineRegistry.localID))
        #expect(throws: ActionFailure.self) { try MachineIconHandlers.machineID(target, services) }
        Self.record(services, icon: nil)
        #expect((try? MachineIconHandlers.machineID(target, services)) == MachineRegistry.localID)
    }

    /// With only This Mac, its header is the list's "Projects" title and draws no machine icon,
    /// so its menu offers no machine icon rows (they would change nothing visible).
    @Test func theLoneProjectsHeaderMenuOffersNoMachineIconRows() throws {
        let services = Self.services()
        AppActions.bind(services)
        Self.record(services, icon: "🚀")
        func machineRows(_ sections: [CmuxNextSidebar.SidebarSection]) throws -> [ActionID] {
            let model = SidebarModel(sections: sections)
            let menu = try #require(SidebarContextMenus.menu(for: .section(.machine(.local)), model: model, services: services,
                                                             scope: ThemeScope(level: .room)))
            func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
            return all(menu.items).compactMap { ActionRegistry.menuRun(of: $0)?.id }.filter { $0.rawValue.hasPrefix("machine.") && $0.rawValue.hasSuffix("Icon") }
        }
        let local = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        let cloud = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: CmuxNextSidebar.MachineID("vm-1"), name: "cloud-a1", kind: .cloud)),
                                                    nodes: [])
        #expect(try machineRows([local]) == [], "the lone Projects header draws no machine icon")
        #expect(try machineRows([local, cloud]) == ["machine.setIcon", "machine.clearIcon"], "This Mac's own header offers them")
    }
}
