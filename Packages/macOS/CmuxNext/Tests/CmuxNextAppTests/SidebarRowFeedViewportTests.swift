import CmuxNextSidebar
import Testing

/// The near-viewport experiment keeps the structural row data available while avoiding
/// observation work for rows that are far outside the realized document.
@MainActor @Suite struct SidebarRowFeedViewportTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    @Test func offscreenRowsStayUnobservedUntilShown() {
        let ids = (0..<400).map { WorkspaceID("w\($0)") }
        var titles = Dictionary(uniqueKeysWithValues: ids.map { ($0, "old-\($0.rawValue)") })
        var maps = 0
        var patches: [SidebarWorkspace] = []
        let feed = SidebarRowFeed(schedule: { _ in })
        feed.onChange = { patches.append(contentsOf: $0) }

        func pass() -> [SidebarSection] {
            feed.beginPass(inputs: 0)
            let rows = ids.map { id in
                feed.row(id, machine: .local) {
                    maps += 1
                    return SidebarWorkspace(id: id, machineID: .local, title: titles[id]!)
                }
            }
            return [SidebarSection(kind: .machine(Self.machine), nodes: rows.map { .workspace($0) })]
        }

        feed.watch(drawn: Set(ids), near: Set(ids.prefix(30)))
        let first = feed.fill(pass())
        #expect(first.flatMap(\.workspaces).count == ids.count)
        #expect(maps == ids.count)

        titles[ids[399]] = "new-offscreen"
        let second = feed.fill(pass())
        #expect(second.flatMap(\.workspaces).last?.title == "old-w399")
        #expect(maps == ids.count)
        #expect(patches.isEmpty)

        feed.watch(near: Set(ids.prefix(30)).union([ids[399]]))
        #expect(maps == ids.count + 1)
        #expect(patches.map(\.title) == ["new-offscreen"])
    }

    @Test func noWatchKeepsAllRowsObserved() {
        let id = WorkspaceID("default")
        var title = "first"
        let feed = SidebarRowFeed(schedule: { _ in })
        func pass(_ inputs: Int) -> SidebarSection {
            feed.beginPass(inputs: inputs)
            let row = feed.row(id, machine: .local) { SidebarWorkspace(id: id, machineID: .local, title: title) }
            return SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(row)])
        }
        _ = feed.fill([pass(0)])
        title = "second"
        #expect(feed.fill([pass(1)]).flatMap(\.workspaces).first?.title == "second")
    }
}
