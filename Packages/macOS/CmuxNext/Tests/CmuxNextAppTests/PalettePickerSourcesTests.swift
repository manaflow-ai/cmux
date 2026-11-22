import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextPalette
import Foundation
import Testing

/// An action with a required argument of kind K asks for K in the palette, which lists the
/// objects `PaletteSourcesBridge.targetSource` gives for K. No source listed spaces, panes, tab
/// groups or workspace groups, so New Workspace in Space…, Swap with Session…, Add Tab to
/// Group…, Reopen Saved Tab Group… and the rest opened an empty list and could never run from
/// the app (unimpl-audit-actions rows 2-10). The guard covers every catalog action, so a new
/// action of a kind nothing lists fails here.
@MainActor @Suite(.serialized) struct PalettePickerSourcesTests {
    /// One window over workspace `k1` (two panes; the first holds tab group API, saved group
    /// Kept is open elsewhere as nothing, Parked is saved and closed), in workspace group Team,
    /// on a daemon with the spaces Default and Work and screen group Front.
    struct Fixture {
        let services: AppServices
        let controller: WindowController

        func close() {
            controller.teardown()
            controller.window?.close()
        }
    }

    static func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let api = TabGroupSnapshot(id: "tg-api", name: "API", savedID: "saved-api", surfaces: [1])
        let first = PaneSnapshot(id: 1, name: "Server", tabs: [TabSnapshot(surface: 1), TabSnapshot(surface: 2)], tabGroups: [api])
        let second = PaneSnapshot(id: 2, name: "Logs", tabs: [TabSnapshot(surface: 3)])
        var workspace = WorkspaceSnapshot(id: 1, key: "k1", name: "Alpha", screens: [
            ScreenSnapshot(id: 1, layout: .leaf(1), panes: [first], group: "sg-front"),
            ScreenSnapshot(id: 2, layout: .leaf(2), panes: [second]),
        ])
        workspace.screenGroups = [ScreenGroupSnapshot(id: "sg-front", name: "Front", screens: [1])]
        var tree = DaemonTree(registryID: "s-local", workspaces: [workspace], savedTabGroups: [
            SavedTabGroupSnapshot(id: "saved-api", name: "API", openGroup: "tg-api"),
            SavedTabGroupSnapshot(id: "saved-parked", name: "Parked"),
        ])
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: [ProfileSnapshot(id: .defaultProfile, name: "Default", index: 0), ProfileSnapshot(id: "work", name: "Work", index: 1)],
            groups: [WorkspaceGroupSnapshot(id: "g-team", name: "Team")],
            workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: "k1", index: 0, group: "g-team")])
        store.apply(snapshot: tree)
        services.windows.registry.provisional["picker-window"] = ["k1"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "picker-window"))
        services.windows.select("k1", in: controller.state)
        controller.showWorkspace(requested: controller.state.workspaceID)
        // The sidebar and the shown content reach the window on observation turns.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline,
              controller.content == nil || !controller.sidebar.model.sections.flatMap(\.nodes).contains(where: { if case .group = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        return Fixture(services: services, controller: controller)
    }

    /// The Priority view's chats on one acpmux: a finished result nobody saw, and a question.
    /// The app lists this Mac's and the Chief's (`AgentPriorityChats.app`); a test has none.
    static let priorityChats: AgentPriorityChats = {
        let store = AgentLaneStore()
        store.socketPath = "/tmp/picker-acpmux.sock"
        store.live = true
        let since = Date().addingTimeInterval(-20 * 60)
        for (id, state, unread) in [("done", AgentActivityLane.State.idle, true), ("asks", .input, false)] {
            store.lanes[id] = AgentActivityLane(id: id, name: id, title: "Chat \(id)", peer: nil, parent: nil, state: state,
                                                since: since, error: nil, unread: unread, project: "cmux")
        }
        return AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store]) { _, _ in }
    }()

    /// The options the palette lists when `descriptor` asks for `argument` (its other required
    /// arguments already given), as the palette's argument page builds them.
    static func listed(_ descriptor: ActionDescriptor, _ argument: ActionArgument, _ services: AppServices) -> [PaletteItem]? {
        var collected = ActionInvocation()
        for other in descriptor.arguments where other.isRequired && other.name != argument.name {
            collected.arguments[other.name] = .string("x")
        }
        let targets = PaletteSourcesBridge.targetSource(services, chats: priorityChats)
        let flow = PaletteArgumentFlow(registry: services.registry, descriptor: descriptor, targets: targets)
        guard case .push(let page) = flow.effect(collected: collected).resolved() else { return nil }
        return page.providers.flatMap { $0.immediateItems ?? [] }
    }

    static func listed(_ id: ActionID, _ services: AppServices) throws -> [PaletteItem] {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
        let argument = try #require(descriptor.arguments.first { if case .target = $0.kind { $0.isRequired } else { false } })
        return try #require(listed(descriptor, argument, services), "\(id) does not open a list")
    }

    @Test func everyRequiredTargetArgumentListsItsObjects() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        var empty: [String] = []
        for descriptor in ActionCatalog.all {
            for argument in descriptor.arguments where argument.isRequired {
                guard case .target(let kind) = argument.kind else { continue }
                if Self.listed(descriptor, argument, fixture.services)?.isEmpty != false {
                    empty.append("\(descriptor.id.rawValue) \(argument.name) (\(kind.rawValue))")
                }
            }
        }
        #expect(empty.isEmpty, "the palette lists nothing for:\n\(empty.joined(separator: "\n"))")
    }

    /// Mark Chat as Read…, Pin/Unpin Chat in Priority… and Snooze Chat for 1 Hour… ask which
    /// chat and list the Priority view's chats (#23527 listed none in the picker test).
    @Test func thePriorityRowActionsListThePriorityChats() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        for id in ["sidebar.priority.markRead", "sidebar.priority.togglePin", "sidebar.priority.snooze"] as [ActionID] {
            let listed = try Self.listed(id, fixture.services)
            #expect(Set(listed.map(\.title)) == ["Chat done", "Chat asks"], "\(id)")
        }
    }

    @Test func theSpacePickerListsEverySpaceInOrder() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        for id in ["space.newWorkspace", "space.newWindow", "space.switch", "workspace.moveToSpace"] as [ActionID] {
            #expect(try Self.listed(id, fixture.services).map(\.title) == ["Default", "Work"], "\(id)")
        }
    }

    /// Swap with Session… lists both panes, the focused one last, and the picked row names
    /// that pane (a pane's own id holds a colon: `pane:2`).
    @Test func swapWithSessionListsThePanesAndPicksTheChosenOne() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        let items = try Self.listed("palette.swapWithSession", fixture.services)
        #expect(Set(items.map(\.title)) == ["Server", "Logs"])
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "palette.swapWithSession" })
        let logs = try #require(items.first { $0.title == "Logs" })
        let value = try #require(PaletteArgumentFlow.optionValue(logs))
        #expect(descriptor.arguments.first?.parse(value) == .target(ActionTargetRef(kind: .pane, id: "pane:2")))
    }

    /// Add Tab to Group… lists the open groups; Delete Saved Tab Group… every saved group;
    /// Reopen Saved Tab Group… only a saved group that is not open.
    @Test func theTabGroupPickersListOpenOrSavedGroups() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        #expect(try Self.listed("tabGroup.addTab", fixture.services).compactMap(PaletteArgumentFlow.optionValue) == ["tg-api"])
        #expect(try Self.listed("tabGroup.deleteSaved", fixture.services).compactMap(PaletteArgumentFlow.optionValue) == ["saved-api", "saved-parked"])
        #expect(try Self.listed("tabGroup.reopenSaved", fixture.services).compactMap(PaletteArgumentFlow.optionValue) == ["saved-parked"])
    }

    /// Move Workspace to Group… from the palette lists the window's workspace groups again
    /// (810d14adeb8 dropped the list with the right-click submenu's own rule).
    @Test func moveToGroupListsTheWindowsGroups() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        #expect(try Self.listed("moveWorkspaceToGroup", fixture.services).map(\.title) == ["Team"])
    }
}
