import CmuxNextAgentPane
import CmuxNextCompat
@testable import CmuxNextDaemon
import Testing

/// What ONE change in ONE workspace costs the holder of the New Tab bar's kept rows (``NewTabPlacesKept``) in a
/// session of 826 workspaces, with a store only (no app, no window): the workspaces that a pass over the holder's
/// list visits. The count is the module's own work counter (``ObservationWork``), which the test sets around the
/// holder's start. After each step the kept rows and the kept folders are those of a walk over every workspace of
/// the store, made then. The same counter gives the workspaces whose folders the holder joined again, and the
/// test counts the calls of the holder's `changed`.
@MainActor @Suite
struct NewTabPlacesKeptCostTests {
    @MainActor final class Events {
        var count = 0
    }

    /// The time since `start`, in milliseconds.
    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
    }

    /// A title change of one tab and a folder change of one tab visit no other workspace in a pass over the list;
    /// a workspace that comes or goes has no condition on its visits (a change of the list makes one pass). The
    /// print has each count, and the time of one join of the folders of all workspaces (a report, no condition).
    ///
    /// The holder's `changed` runs one time for a title change, one time for a folder change, and one time for
    /// the title changes of 2 tabs of 2 workspaces in one turn. The holder joins the folders of no workspace for
    /// a title change and of every workspace, one time, for a folder change.
    ///
    /// The sign that the holder took a change is a condition of the setup: its `changed` ran for the step.
    @Test func aChangeOfOneRowOrOneFolderVisitsNoOtherWorkspaceAndTheKeptRowsStayTheWalks() async throws {
        let size = SessionFixtureSize.real
        let fixture = LargeSessionFixture(size)
        let store = fixture.store
        let kept = NewTabPlacesKept(home: "/Users/you")
        let events = Events()
        let work = ObservationWork()
        ObservationWork.$current.withValue(work) {
            kept.follow(list: { [store] in store.workspaces },
                        rows: { [weak kept] workspace in kept?.mapped(workspace, machine: nil) },
                        changed: { events.count += 1 })
        }
        await LargeSessionFixture.drainMain()
        await LargeSessionFixture.drainMain()
        let first = kept.rows?.count ?? -1
        try #require(first == size.workspaces, "setup: the holder kept the rows of \(first) workspaces after the drain, want \(size.workspaces)")

        /// Every workspace's rows, made now: what the kept rows must be.
        func walk() -> [NewTabPlaces.Rows] { store.workspaces.map { kept.mapped($0, machine: nil) } }
        /// Makes one change, lets the main actor run, and gives what the holder's work visited for it, by step, and
        /// how many times its `changed` ran.
        func step(_ change: () -> Void) async -> (visits: [String: Int], events: Int) {
            work.reset()
            let before = events.count
            change()
            await LargeSessionFixture.drainMain()
            await LargeSessionFixture.drainMain()
            return (work.byStep, events.count - before)
        }

        let terminals = fixture.tabs().filter { $0.tab.kind == .pty }
        let place = try #require(terminals.dropFirst(terminals.count / 2).first, "setup: the session has no terminal")

        let title = await step { place.tab.titleText = "kept row" }
        let titled = walk()
        try #require(title.events >= 1, "setup: the holder's `changed` did not run for the title change")
        try #require(titled.contains(where: { rows in rows.tabs.contains(where: { $0.title == "kept row" }) }),
                     "setup: the walk does not have the changed title")
        let titleListed = title.visits["ObservedItems.list"] ?? 0
        #expect(kept.rows == titled, "the kept rows are not the walk's rows after a title change")
        #expect(kept.folders == NewTabPlaces.folders(titled), "the kept folders are not the walk's folders after a title change")
        #expect(titleListed == 0, "a title change of one tab visited \(titleListed) workspaces of \(size.workspaces) in passes over the list, want 0")
        let titleJoined = title.visits["NewTabPlacesKept.join"] ?? 0
        #expect(title.events == 1, "the holder's `changed` ran \(title.events) times for a title change of one tab, want 1")
        #expect(titleJoined == 0, "a title change of one tab joined the folders of \(titleJoined) workspaces, want 0")

        let foldersBefore = kept.folders
        let folder = await step { place.tab.cwd = "/tmp/large/kept/src" }
        let moved = walk()
        try #require(folder.events >= 1, "setup: the holder's `changed` did not run for the folder change")
        try #require(NewTabPlaces.folders(moved) != foldersBefore, "setup: the folder change did not change the walk's folders")
        let folderListed = folder.visits["ObservedItems.list"] ?? 0
        #expect(kept.rows == moved, "the kept rows are not the walk's rows after a folder change")
        #expect(kept.folders == NewTabPlaces.folders(moved), "the kept folders are not the walk's folders after a folder change")
        #expect(folderListed == 0,
                "a folder change of one tab visited \(folderListed) workspaces of \(size.workspaces) in passes over the list, want 0")
        let folderJoined = folder.visits["NewTabPlacesKept.join"] ?? 0
        #expect(folder.events == 1, "the holder's `changed` ran \(folder.events) times for a folder change of one tab, want 1")
        #expect(folderJoined == size.workspaces,
                "a folder change of one tab joined the folders of \(folderJoined) workspaces, want one join of \(size.workspaces)")

        // 2 tabs of 2 workspaces change in one turn: the holder takes 2 changes and calls `changed` one time.
        let second = try #require(terminals.first(where: { $0.workspace != place.workspace }),
                                  "setup: the session has no terminal in a second workspace")
        let pair = await step {
            place.tab.titleText = "kept row 2"
            second.tab.titleText = "kept row 3"
        }
        let paired = walk()
        let pairMapped = pair.visits["ObservedItems.map"] ?? 0
        let pairListed = pair.visits["ObservedItems.list"] ?? 0
        try #require(pairMapped == 2, "setup: the title changes of 2 tabs of 2 workspaces in one turn mapped \(pairMapped) workspaces, want 2")
        let pairTitled = paired.filter { rows in rows.tabs.contains(where: { $0.title == "kept row 2" || $0.title == "kept row 3" }) }.count
        try #require(pairTitled == 2, "setup: the walk has the 2 changed titles in \(pairTitled) workspaces, want 2")
        #expect(kept.rows == paired, "the kept rows are not the walk's rows after the title changes of 2 tabs in one turn")
        #expect(pairListed == 0, "the title changes of 2 tabs in one turn visited \(pairListed) workspaces in passes over the list, want 0")
        #expect(pair.events == 1, "the holder's `changed` ran \(pair.events) times for the changes of 2 workspaces in one turn, want 1")

        var tree = LargeSessionFixture.tree(size)
        let shell = TabSnapshot(surface: SurfaceID(rawValue: 990_002), tabResourceID: ResourceID(rawValue: "tab_kept_shell"), kind: .pty,
                                title: "kept shell", cwd: "/tmp/large/kept-new")
        let pane = PaneSnapshot(id: PaneID(rawValue: 990_001), resourceID: ResourceID(rawValue: "pane_kept"), tabs: [shell])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 990_001), layout: .leaf(pane.id), panes: [pane])
        tree.workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 990_001), key: WorkspaceKey(rawValue: "kept-key"),
                                                 resourceID: ResourceID(rawValue: "ws_kept"), name: "kept", screens: [screen]))
        let came = await step { store.apply(snapshot: tree) }
        let grown = walk()
        try #require(grown.count == size.workspaces + 1, "setup: the store has \(grown.count) workspaces after one came, want \(size.workspaces + 1)")
        #expect(kept.rows == grown, "the kept rows are not the walk's rows after a workspace came")
        #expect(kept.folders == NewTabPlaces.folders(grown), "the kept folders are not the walk's folders after a workspace came")

        tree.workspaces.remove(at: 10)
        let went = await step { store.apply(snapshot: tree) }
        let less = walk()
        try #require(less.count == size.workspaces, "setup: the store has \(less.count) workspaces after one went, want \(size.workspaces)")
        #expect(kept.rows == less, "the kept rows are not the walk's rows after a workspace went")
        #expect(kept.folders == NewTabPlaces.folders(less), "the kept folders are not the walk's folders after a workspace went")

        let began = ContinuousClock.now
        let joined = NewTabPlaces.folders(less)
        let joinTime = Self.milliseconds(since: began)
        print("new tab kept rows, \(size.workspaces) workspaces: a title change visited \(title.visits), a folder change visited \(folder.visits), "
            + "the title changes of 2 tabs of 2 workspaces in one turn visited \(pair.visits) and ran `changed` \(pair.events) time(s), "
            + "a workspace that came visited \(came.visits), a workspace that went visited \(went.visits); "
            + "one join of the folders of all workspaces (\(joined.count) folders) took \(joinTime) ms")
    }
}
