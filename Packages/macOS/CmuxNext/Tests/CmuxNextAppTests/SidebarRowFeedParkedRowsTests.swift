import CmuxNextSidebar
import Observation
import Testing

/// "changing spaces in sidebar also feels kinda slow" (Lawrence 2026-11-10). A window lists one space at a time, and
/// the rows feed forgot every row the last pass did not name: each space switch dropped the rows of the space the
/// window left and mapped every row of the space it showed again, each under a new observation (200 maps per switch
/// at 400 workspaces in two spaces, for a list that draws about 29 rows). The feed parks the rows of a workspace the
/// window still holds: a space shown again maps only the rows that changed while it was hidden, a parked row sends
/// no patch, and a row whose workspace left the window is forgotten.
@MainActor @Suite struct SidebarRowFeedParkedRowsTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// What the rows read: one title per workspace, observed one workspace at a time, and whether each lists.
    final class Source {
        private var cells: [WorkspaceID: Observed] = [:]
        @Observable final class Observed {
            var title: String
            var lists = true
            init(_ title: String) { self.title = title }
        }

        func cell(_ id: WorkspaceID) -> Observed {
            if let cell = cells[id] { return cell }
            let cell = Observed("title \(id.rawValue)")
            cells[id] = cell
            return cell
        }
    }

    /// One window's feed over spaces of rows; its frames run only in `frame()`.
    @MainActor final class Fixture {
        final class Frames { var work: [@MainActor @Sendable () -> Void] = [] }
        let frames = Frames()
        let source = Source()
        /// The workspaces the window holds (`keeps`).
        var held: Set<WorkspaceID> = []
        private(set) var feed: SidebarRowFeed!
        /// Row maps and listing rule runs, per workspace.
        private(set) var maps: [WorkspaceID: Int] = [:]
        private(set) var rules: [WorkspaceID: Int] = [:]
        /// The rows the feed sent as patches.
        private(set) var patches: [SidebarWorkspace] = []

        init() {
            let frames = frames
            feed = SidebarRowFeed(schedule: { frames.work.append($0) }, keeps: { [unowned self] in self.held.contains($0) })
            feed.onChange = { [unowned self] in self.patches += $0 }
        }

        static func space(_ name: String, _ count: Int = 200) -> [WorkspaceID] { (0..<count).map { WorkspaceID("\(name)\($0)") } }

        /// The structural pass and its fill for a window that shows `space`: the rows that list, filled.
        @discardableResult func show(_ space: [WorkspaceID], inputs: Int = 0) -> [SidebarWorkspace] {
            held.formUnion(space)
            feed.beginPass(inputs: inputs)
            let source = source
            let listed = space.filter { id in
                feed.lists(id) { [unowned self] in
                    self.rules[id, default: 0] += 1
                    return source.cell(id).lists
                }
            }
            let rows = listed.map { id in
                feed.row(id, machine: .local) { [unowned self] in
                    self.maps[id, default: 0] += 1
                    return SidebarWorkspace(id: id, machineID: .local, title: "\(source.cell(id).title) inputs \(inputs)")
                }
            }
            return feed.fill([SidebarSection(kind: .machine(SidebarRowFeedParkedRowsTests.machine), nodes: rows.map { .workspace($0) })]).flatMap(\.workspaces)
        }

        /// Runs the work the feed scheduled for the frame (its flush, its checks).
        func frame() {
            while !frames.work.isEmpty {
                let work = frames.work
                frames.work.removeAll()
                for item in work { item() }
            }
        }

        var mapCount: Int { maps.values.reduce(0, +) }
        var ruleCount: Int { rules.values.reduce(0, +) }
    }

    @Test func aSpaceShownAgainMapsNoRowAndRunsNoRule() {
        let fixture = Fixture(), a = Fixture.space("a"), b = Fixture.space("b")
        #expect(fixture.show(a).map(\.title) == a.map { "title \($0.rawValue) inputs 0" })
        fixture.frame()
        fixture.show(b)
        fixture.frame()
        let (maps, rules) = (fixture.mapCount, fixture.ruleCount)
        #expect(maps == 400)
        for round in 0..<4 {
            let space = round % 2 == 0 ? a : b
            let rows = fixture.show(space)
            fixture.frame()
            #expect(rows.map(\.id) == space && rows.allSatisfy { $0.title == "title \($0.id.rawValue) inputs 0" }, "switch \(round) lists other rows")
        }
        #expect(fixture.mapCount == maps, "a space shown before mapped \(fixture.mapCount - maps) rows again in 4 switches")
        #expect(fixture.ruleCount == rules, "a space shown before ran \(fixture.ruleCount - rules) listing rules again in 4 switches")
        #expect(fixture.patches.isEmpty)
    }

    @Test func aRowChangedWhileParkedSendsNoPatchAndMapsOnceWhenItsSpaceShows() {
        let fixture = Fixture(), a = Fixture.space("a"), b = Fixture.space("b")
        fixture.show(a)
        fixture.show(b)
        fixture.frame()
        let maps = fixture.mapCount, changed = a[5]
        for tick in 0..<20 { fixture.source.cell(changed).title = "tick \(tick)" } // an agent's status ticks in the hidden space
        fixture.frame()
        #expect(fixture.mapCount == maps, "a row nobody sees was mapped \(fixture.mapCount - maps) times")
        #expect(fixture.patches.isEmpty, "a row nobody sees sent \(fixture.patches.count) patches")
        let rows = fixture.show(a)
        #expect(rows.first { $0.id == changed }?.title == "tick 19 inputs 0", "the row shows an old title when its space shows again")
        #expect(fixture.mapCount == maps + 1, "showing the space mapped \(fixture.mapCount - maps) rows for one changed row")
        // Listed again, the row patches as any listed row does.
        fixture.frame()
        fixture.source.cell(changed).title = "shown"
        fixture.frame()
        #expect(fixture.patches.map(\.title) == ["shown inputs 0"])
    }

    @Test func aRowPendingAPatchWhenItsSpaceLeavesMapsWhenTheSpaceShowsAgain() {
        let fixture = Fixture(), a = Fixture.space("a"), b = Fixture.space("b")
        fixture.show(a)
        fixture.frame()
        fixture.source.cell(a[3]).title = "late" // dirty, its flush not run yet
        fixture.show(b)
        fixture.frame()
        #expect(fixture.patches.isEmpty, "a row of the space the window left sent a patch")
        #expect(fixture.show(a).first { $0.id == a[3] }?.title == "late inputs 0")
    }

    @Test func aParkedRowOfAWorkspaceTheWindowLostIsForgotten() {
        let fixture = Fixture(), a = Fixture.space("a"), b = Fixture.space("b"), c = Fixture.space("c", 3)
        fixture.show(a)
        fixture.show(b)
        fixture.frame()
        // One workspace of the hidden space closes; one of the shown space moves to another window.
        fixture.held.subtract([a[7], b[9]])
        fixture.show(c) // b's rows park, but not the one the window lost; the check of the parked rows runs with the frame
        fixture.frame()
        let maps = fixture.maps
        fixture.held.formUnion([a[7], b[9]]) // the same ids list here again (a move back)
        fixture.show(a)
        fixture.show(b)
        let again = Set((a + b).filter { fixture.maps[$0] != maps[$0] })
        #expect(again == [a[7], b[9]], "rows mapped again: \(again.map(\.rawValue).sorted())")
    }

    /// A parked workspace closes (or another window takes it) while its space is hidden. No row parks then and no
    /// parked row hears a change, so nothing asked for the check of the parked rows: its row, its map closure and
    /// its observation stayed until the next space switch. The next pass's fill asks for the check too.
    @Test func aParkedRowOfAWorkspaceTheWindowLostIsForgottenByTheNextPass() {
        let fixture = Fixture(), a = Fixture.space("a", 20), b = Fixture.space("b", 20)
        fixture.show(a)
        fixture.show(b)
        fixture.frame()
        fixture.held.remove(a[7]) // it closes while space a is hidden
        fixture.show(b) // a pass of the shown space that parks nothing (a reorder, a new row)
        fixture.frame()
        let maps = fixture.maps
        fixture.held.insert(a[7]) // the same id lists here again
        fixture.show(a)
        let again = a.filter { fixture.maps[$0] != maps[$0] }
        #expect(again == [a[7]], "the row of the workspace the window lost was kept parked; rows mapped again: \(again.map(\.rawValue))")
    }

    /// A batch that can fail (the face rules could not read their reply).
    final class Batch: SidebarRowBatch {
        var runs = true
        func begin() {}
        func run() -> Bool { runs }
    }

    /// A row whose last batch could not run reads nothing that tells it to map again. Before the feed parked rows, a
    /// space shown again mapped it (its row was new); a parked one stayed as it was (no title, or its old content).
    @Test(arguments: [false, true]) func aParkedRowWhoseBatchCouldNotRunMapsWhenItsSpaceShowsAgain(mappedBefore: Bool) {
        let batch = Batch(), frames = Fixture.Frames(), a = WorkspaceID("a0"), b = WorkspaceID("b0")
        let feed = SidebarRowFeed(schedule: { frames.work.append($0) }, keeps: { _ in true })
        var title = "first"
        /// One pass of a window that shows the space of `id` alone; its row's title after the fill.
        func show(_ id: WorkspaceID, inputs: Int) -> String? {
            feed.beginPass(inputs: inputs)
            let make = SidebarRowFeed.Make(batch: batch, stage: { 0 }, finish: { _ in SidebarWorkspace(id: id, machineID: .local, title: title) })
            let row = feed.row(id, machine: .local, make: make)
            return feed.fill([SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(row)])]).flatMap(\.workspaces).first?.title
        }
        if mappedBefore { #expect(show(a, inputs: 0) == "first") }
        (batch.runs, title) = (false, "second")
        // The pass maps the row (it is new, or the inputs changed) and its batch cannot run.
        #expect(show(a, inputs: 1) == (mappedBefore ? "first" : ""))
        batch.runs = true
        _ = show(b, inputs: 1) // space a hides: its row parks
        #expect(show(a, inputs: 1) == "second", "the row parked after a batch that could not run was not mapped again")
    }

    @Test func aParkedRowMappedWithOldInputsIsNotServed() {
        let fixture = Fixture(), a = Fixture.space("a", 20), b = Fixture.space("b", 20)
        fixture.show(a, inputs: 0)
        fixture.show(b, inputs: 0)
        fixture.show(b, inputs: 1) // the muted set changes while space a is hidden
        let rows = fixture.show(a, inputs: 1)
        #expect(rows.allSatisfy { $0.title.hasSuffix("inputs 1") }, "rows mapped with old inputs: \(rows.filter { !$0.title.hasSuffix("inputs 1") }.map(\.title))")
    }

    /// The pass that parks a space can be the one whose inputs change (a mute and a space switch in one turn): the
    /// rows it parks were mapped with the old inputs, and no later pass with the new inputs maps them again.
    @Test func aRowParkedByThePassThatChangesTheInputsIsNotServedWithOldInputs() {
        let fixture = Fixture(), a = Fixture.space("a", 20), b = Fixture.space("b", 20)
        fixture.show(a, inputs: 0)
        fixture.show(b, inputs: 1) // the muted set changes in the pass that leaves space a
        let rows = fixture.show(a, inputs: 1)
        #expect(rows.allSatisfy { $0.title.hasSuffix("inputs 1") }, "rows mapped with old inputs: \(rows.filter { !$0.title.hasSuffix("inputs 1") }.map(\.title))")
    }

    @Test func aListingChangedWhileParkedAnswersWhenItsSpaceShows() {
        let fixture = Fixture(), a = Fixture.space("a", 20), b = Fixture.space("b", 20)
        fixture.show(a)
        fixture.show(b)
        fixture.frame()
        let rules = fixture.ruleCount
        fixture.source.cell(a[2]).lists = false // its chat's session ended while the space was hidden
        fixture.frame()
        #expect(fixture.ruleCount == rules, "a listing nobody asks for ran its rule")
        #expect(fixture.show(a).map(\.id) == a.filter { $0 != a[2] })
        fixture.frame()
        fixture.source.cell(a[2]).lists = true
        fixture.frame()
        #expect(fixture.show(a).map(\.id) == a)
    }
}
