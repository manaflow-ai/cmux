import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-23: "there is a lot of lag in terminal, when stuff in sidebar rearranges". A reorder (a
/// workspace moves to the top, changes group) runs the structural rows pass, and `SidebarRowFeed.fill` then wrote
/// every row of the sidebar again although the pass already held each current row: at 400 workspaces that rewrite
/// was most of the reorder's main-thread time (Time Profiler, sidebar-churn-typing.py), and a key typed in a
/// terminal waited behind it. A reorder must write no row; only a new or newly mapped row is written.
@MainActor @Suite struct SidebarReorderFillCostTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// A long, fully mapped row (its make runs only on the first pass).
    static func mapped(_ id: WorkspaceID) -> SidebarWorkspace {
        SidebarWorkspace(id: id, machineID: .local, title: "Agent workspace \(id.rawValue) with a longer title",
                         directory: "~/fun/cmux-worktrees/\(id.rawValue)", branch: "feat-\(id.rawValue)",
                         status: "Running fleet tests, step \(id.rawValue)")
    }

    /// One structural pass over `order`: the first 100 ids in ten groups of ten, the rest loose.
    static func pass(_ feed: SidebarRowFeed, _ order: [WorkspaceID]) -> [SidebarSection] {
        feed.beginPass(inputs: 0)
        let rows = order.map { id in feed.row(id, machine: .local) { mapped(id) } }
        var nodes: [SidebarNode] = []
        for g in 0..<10 {
            let members = Array(rows[(g * 10)..<(g * 10 + 10)])
            nodes.append(.group(SidebarGroup(id: GroupID("g\(g)"), name: "Group \(g)", color: .green, workspaces: members)))
        }
        nodes += rows[100...].map { .workspace($0) }
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func storage(_ sections: [SidebarSection]) -> [UnsafeRawPointer?] {
        [sections.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }]
            + sections.map { $0.nodes.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
    }

    @Test func aReorderWritesNoRow() {
        let feed = SidebarRowFeed(schedule: { _ in })
        var order = (0..<500).map { WorkspaceID("w\($0)") }
        let first = feed.fill(Self.pass(feed, order))
        #expect(first.flatMap(\.workspaces).allSatisfy { !$0.title.isEmpty }) // the first pass maps every row
        // A workspace moves to the top, another moves into a group: the pass names the same rows in a new order.
        order.insert(order.remove(at: 400), at: 0)
        order.swapAt(5, 300)
        let reordered = Self.pass(feed, order)
        let filled = feed.fill(reordered)
        #expect(filled == reordered)
        // Nothing was written: the fill hands the pass's sections back as they are, no row copied.
        #expect(Self.storage(filled) == Self.storage(reordered))
    }

    @Test func aNewRowIsStillFilled() {
        let feed = SidebarRowFeed(schedule: { _ in })
        var order = (0..<200).map { WorkspaceID("w\($0)") }
        _ = feed.fill(Self.pass(feed, order))
        order.insert(WorkspaceID("new"), at: 0)
        let filled = feed.fill(Self.pass(feed, order))
        let rows = Dictionary(uniqueKeysWithValues: filled.flatMap(\.workspaces).map { ($0.id, $0) })
        #expect(rows[WorkspaceID("new")] == Self.mapped(WorkspaceID("new")))
        #expect(rows[WorkspaceID("w150")] == Self.mapped(WorkspaceID("w150")))
    }

    @Test func newInputsFillEveryRowAgain() {
        let feed = SidebarRowFeed(schedule: { _ in })
        let order = (0..<120).map { WorkspaceID("w\($0)") }
        var title = "first"
        func pass(_ inputs: Int) -> [SidebarSection] {
            feed.beginPass(inputs: inputs)
            let rows = order.map { id in feed.row(id, machine: .local) { SidebarWorkspace(id: id, machineID: .local, title: title) } }
            return [SidebarSection(kind: .machine(Self.machine), nodes: rows.map { .workspace($0) })]
        }
        _ = feed.fill(pass(0))
        title = "second"
        let filled = feed.fill(pass(1))
        #expect(filled.flatMap(\.workspaces).allSatisfy { $0.title == "second" })
    }
}
