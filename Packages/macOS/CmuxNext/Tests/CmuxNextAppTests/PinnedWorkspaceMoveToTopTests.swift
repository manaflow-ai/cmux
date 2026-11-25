import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Move Workspace to Top on a pinned workspace was refused with "the workspace is not in the
/// sidebar" (Lawrence 2026-11-20): a pinned workspace is an item of the Pinned band, not a row
/// of the workspace list, and Move to Top, Move to Bottom and Move Above/Below only looked at
/// the list rows. Now each moves the workspace among the items of Pinned: to the top of the
/// pinned block (right under Home), to its bottom, or next to another pinned workspace.
@MainActor @Suite(.serialized) struct PinnedWorkspaceMoveToTopTests {
    struct Fixture {
        let services: AppServices
        let workspaces: [WorkspaceModel]

        func pinnedOrder() -> [String] {
            services.sidebarLayout.document.section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.id.rawValue) ?? []
        }

        func topOrder() -> [String] {
            services.sidebarLayout.document.section(SidebarLayoutDocument.topSectionID)?.items.map(\.id.rawValue) ?? []
        }

        /// Runs `id` on workspace `name` as the palette does, and returns the refusal, if any.
        func perform(_ id: ActionID, _ name: String, anchor: String? = nil) throws -> String? {
            let workspace = try #require(workspaces.first { $0.name == name })
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace.id))
            invocation.origin = .user
            if let anchor, let other = workspaces.first(where: { $0.name == anchor }) {
                invocation.arguments["anchor"] = .target(ActionTargetRef(kind: .workspace, id: other.id))
            }
            return services.registry.capturingRefusal { _ = services.registry.perform(id, invocation: invocation) }
        }
    }

    /// Three open workspaces a, b and c, pinned in that order under Home (the layout's own
    /// copy, no daemon owner), and no window: no workspace list lists a row for them.
    static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.sidebarLayout = SidebarLayoutService(prototypeEnabled: { true })
        AppActions.bind(services)
        let daemon = services.machines.local
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["workspace-registry-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        daemon.store.noteHandshake(identity)
        daemon.store.connectionState = .connected(identity)
        daemon.store.apply(snapshot: DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "k-a"), resourceID: ResourceID(rawValue: "ws_a"), name: "a"),
            WorkspaceSnapshot(id: 2, key: WorkspaceKey(rawValue: "k-b"), resourceID: ResourceID(rawValue: "ws_b"), name: "b"),
            WorkspaceSnapshot(id: 3, key: WorkspaceKey(rawValue: "k-c"), resourceID: ResourceID(rawValue: "ws_c"), name: "c"),
        ]))
        let items = ["a", "b", "c"].map { LayoutItem(id: LayoutItemID("itm_\($0)"), ref: .workspace("s-local:ws_\($0)")) }
        try services.sidebarLayout.send(.sectionAdd(SidebarLayoutDocument.pinnedSection(items: items), index: 1))
        return Fixture(services: services, workspaces: daemon.store.workspaces)
    }

    @Test func moveToTopPutsAPinnedWorkspaceFirstUnderHome() throws {
        let fixture = try Self.fixture()
        let homeBefore = fixture.topOrder()
        let reason = try fixture.perform("palette.moveWorkspaceToTop", "c")
        #expect(reason == nil, "Move to Top on a pinned workspace was refused: \(reason ?? "")")
        #expect(fixture.pinnedOrder() == ["itm_c", "itm_a", "itm_b"])
        #expect(fixture.topOrder() == homeBefore, "Home stays above the pinned block")
    }

    @Test func moveToTopOfTheFirstPinnedWorkspaceIsANoOpNotARefusal() throws {
        let fixture = try Self.fixture()
        let reason = try fixture.perform("palette.moveWorkspaceToTop", "a")
        #expect(reason == nil, "Move to Top on the first pinned workspace was refused: \(reason ?? "")")
        #expect(fixture.pinnedOrder() == ["itm_a", "itm_b", "itm_c"])
    }

    @Test func moveToBottomPutsAPinnedWorkspaceLast() throws {
        let fixture = try Self.fixture()
        let reason = try fixture.perform("workspace.moveToBottom", "a")
        #expect(reason == nil, "Move to Bottom on a pinned workspace was refused: \(reason ?? "")")
        #expect(fixture.pinnedOrder() == ["itm_b", "itm_c", "itm_a"])
    }

    @Test func moveAboveAndBelowAnotherPinnedWorkspace() throws {
        let fixture = try Self.fixture()
        #expect(try fixture.perform("workspace.moveAbove", "c", anchor: "a") == nil)
        #expect(fixture.pinnedOrder() == ["itm_c", "itm_a", "itm_b"])
        #expect(try fixture.perform("workspace.moveBelow", "c", anchor: "b") == nil)
        #expect(fixture.pinnedOrder() == ["itm_a", "itm_b", "itm_c"])
    }

    @Test func moveUpAndDownStillStepAmongThePinnedItems() throws {
        let fixture = try Self.fixture()
        #expect(try fixture.perform("moveWorkspaceUp", "b") == nil)
        #expect(fixture.pinnedOrder() == ["itm_b", "itm_a", "itm_c"])
        #expect(try fixture.perform("moveWorkspaceDown", "b") == nil)
        #expect(fixture.pinnedOrder() == ["itm_a", "itm_b", "itm_c"])
    }
}
