#if DEBUG
import Foundation

/// JSON-backed input for the native gallery's sidebar entries.
public nonisolated struct SidebarGalleryFixture: Codable, Sendable {
    public enum Scenario: String, Codable, CaseIterable, Sendable {
        case sessionTreeDeep = "session-tree-deep"
        case sidebarCustomization = "sidebar-customization"
        case needsYou = "needs-you"
    }

    public let scenario: Scenario

    public init(scenario: Scenario) {
        self.scenario = scenario
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }

    /// The native model and session-tree state consumed by the capture.
    public var snapshot: Snapshot {
        switch scenario {
        case .sessionTreeDeep:
            return Self.deepTree()
        case .sidebarCustomization:
            let fixture = SidebarNestedFixture(scenario: .soleMember)
            return Snapshot(sections: fixture.sections, tree: SidebarSessionTreeState(), width: fixture.width)
        case .needsYou:
            let fixture = SidebarNestedFixture(scenario: .needsYou)
            let states = Dictionary(uniqueKeysWithValues: fixture.sections.flatMap(\.workspaces).map {
                ($0.id, SidebarAgentState.of($0, lane: nil))
            })
            return Snapshot(sections: fixture.sections,
                           tree: SidebarSessionTreeState(parents: fixture.parents, states: states), width: fixture.width)
        }
    }

    public struct Snapshot: Sendable {
        public let sections: [SidebarSection]
        public let tree: SidebarSessionTreeState
        public let width: Double

        public var rowIDs: [String] { sections.flatMap(\.workspaces).map(\.id.rawValue) }
    }

    private static func deepTree() -> Snapshot {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let root = SidebarWorkspace(id: WorkspaceID("w-orchestrator"), title: "Orchestrator", activity: .working)
        let build = SidebarWorkspace(id: WorkspaceID("w-build"), title: "Build and package", activity: .working)
        let checks = SidebarWorkspace(id: WorkspaceID("w-checks"), title: "Run checks", activity: .waiting(kind: .question))
        var review = SidebarWorkspace(id: WorkspaceID("w-review"), title: "Review results", unread: .dot)
        review.activity = .success
        let failed = SidebarWorkspace(id: WorkspaceID("w-failed"), title: "Failed shard", activity: .error)
        let docs = SidebarWorkspace(id: WorkspaceID("w-docs"), title: "Update docs", unread: .count(2))
        let nodes = [root, build, checks, review, failed, docs].map(SidebarNode.workspace)
        let sections = [SidebarSection(kind: .machine(machine), nodes: nodes)]
        let tree = SidebarSessionTreeState(
            parents: [build.id: root.id, checks.id: build.id, review.id: root.id, failed.id: build.id],
            states: [root.id: .running, build.id: .running, checks.id: .blocked, review.id: .finishedUnread,
                     failed.id: .failed, docs.id: .finishedUnread],
            collapsed: [root.id]
        )
        return Snapshot(sections: sections, tree: tree, width: 288)
    }
}
#endif
