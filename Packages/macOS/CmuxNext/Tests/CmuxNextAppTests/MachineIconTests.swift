import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
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
        #expect(DaemonCapabilities.shared.optional.contains("session-icon-v1"))
        #expect(DaemonCapabilities.shared.homeOnly.contains("session-icon-v1"))
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
        #expect(ContextMenuCatalog.shared.entries(for: .machineSection)
            == [.folder(.appearance, [.action("machine.setIcon"), .action("machine.clearIcon")])])
    }

    /// Every machine header's right-click menu offers Set Icon under Appearance, aimed at that
    /// machine, after its own rows (This Mac keeps the sidebar's rows); Remove Icon shows only
    /// while the machine has an icon.
    @Test func thisMacsHeaderMenuOffersItsIconUnderAppearance() throws {
        let services = Self.services()
        AppActions.bind(services)
        func iconRuns() throws -> [(id: ActionID, target: ActionTargetRef?)] {
            let menu = SidebarContextMenus.machineMenu(MachineRegistry.localID, services: services)
            #expect(menu.items.contains { !$0.isSeparatorItem && $0.title != MenuFolder.appearance.title }, "the sidebar's own rows stay")
            let appearance = try #require(menu.items.first { $0.title == MenuFolder.appearance.title }?.submenu)
            return appearance.items.compactMap { ActionRegistry.menuRun(of: $0) }.map { (id: $0.id, target: $0.target) }
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
}
