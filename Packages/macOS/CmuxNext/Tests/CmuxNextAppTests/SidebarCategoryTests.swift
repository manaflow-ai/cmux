@testable import CmuxNextSidebar
import Testing

/// Every sidebar input has a home. The taxonomy is an audit of existing destinations;
/// it does not turn on a new section or change defaults.
struct SidebarCategoryTests {
    @Test func everyPersistedItemTypeHasACategory() {
        let bodies: [SidebarDocBody] = [
            .workspace(.init(sessionID: "local", workspaceID: "ws")),
            .group(name: "Project", color: nil, icon: nil, collapsed: false),
            .builtin(SidebarBuiltIn.home.rawValue),
            .builtin(SidebarBuiltIn.settings.rawValue),
            .app("com.example.app"),
            .url("https://example.com", title: "Example"),
            .tab("tab-1"),
            .room("room-1"),
            .savedGroup("saved"),
            .ref(kind: "future", value: "item"),
            .other("future")
        ]
        #expect(bodies.allSatisfy { SidebarCategory(body: $0).isCategorized })
        #expect(SidebarCategory(body: .other("future")) == .localMachine)
    }

    @Test func lanesUseExistingGroupingDestinations() {
        #expect(SidebarLaneGroup.forLane(peer: "build-mac", workspaceID: nil, parent: nil) == .fleet("build-mac"))
        #expect(SidebarLaneGroup.forLane(peer: "build-mac", workspaceID: nil, parent: "parent", hasLiveParent: true) == .lineage("parent"))
        #expect(SidebarLaneGroup.forLane(peer: nil, workspaceID: "ws-1", parent: nil) == .workspace("ws-1"))
        #expect(SidebarLaneGroup.forLane(peer: nil, workspaceID: nil, parent: "session-1") == .lineage("session-1"))
        #expect(SidebarCategory.lane(peer: "build-mac", workspaceID: nil, parent: nil) == .fleetSession)
        #expect(SidebarCategory.lane(peer: nil, workspaceID: "ws-1", parent: nil) == .agentSession)
    }
}
