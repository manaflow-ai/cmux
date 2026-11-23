@testable import CmuxNextAgentPane
import CmuxNextDaemon
import Testing

/// Lawrence 2026-11-19 (a video, "typing here is very laggy"): with ~1,000 workspaces and 13 agents
/// running, every spinner rename sent every shown page the whole list (4,096 places) and each page parsed
/// it again on the renderer thread all agent pages share; the New Tab page's frames took 100-977 ms. A
/// rename now owes a page the renamed places only.
@MainActor
struct AgentPaneLinkPlacesRenameTests {
    /// A session the size of that Mac's: `count` workspaces of one pane with one tab each.
    static func slices(_ count: Int, title: (Int) -> String = { "shell \($0)" }) -> [[AgentPaneLinkPlaces.Place]] {
        (0..<count).map { index in
            let name = "w\(index)"
            return [
                .init(id: "ws_\(index)", kind: .workspace, title: name),
                .init(id: "pane_\(index)", kind: .pane, title: title(index), workspace: name),
                .init(id: "tab_\(index)", kind: .tab, title: title(index), workspace: name),
            ]
        }
    }

    @Test func aSpinnerRenameIsTheRenamedPlacesOnly() throws {
        let before = Self.slices(1_000)
        let after = Self.slices(1_000) { $0 == 417 ? "⠙ Working" : "shell \($0)" }
        let renamed = try #require(AgentPaneLinkPlaces.renamed(from: before, to: after))
        #expect(renamed.map(\.id) == ["pane_417", "tab_417"])
        #expect(renamed.allSatisfy { $0.title == "⠙ Working" })
        #expect(AgentPaneLinkPlaces.renamed(from: before, to: before) == [])
    }

    @Test func aPlaceThatComesGoesOrMovesOwesTheWholeList() {
        let before = Self.slices(10)
        var came = before
        came[3].append(.init(id: "tab_new", kind: .tab, title: "new", workspace: "w3"))
        #expect(AgentPaneLinkPlaces.renamed(from: before, to: came) == nil)
        #expect(AgentPaneLinkPlaces.renamed(from: before, to: Array(before.dropLast())) == nil)
        var moved = before
        moved[2].swapAt(1, 2)
        #expect(AgentPaneLinkPlaces.renamed(from: before, to: moved) == nil)
    }

    @Test func aPageOwesWhatWasRenamedSinceItsLastPush() {
        let tab = AgentPaneLinkPlaces.Place(id: "tab_1", kind: .tab, title: "a")
        let pane = AgentPaneLinkPlaces.Place(id: "pane_1", kind: .pane, title: "a")
        var owed = AgentPaneLinkPlacesOwed.current
        owed.note(renamed: [tab])
        owed.note(renamed: [tab, pane])
        #expect(!owed.whole)
        #expect(owed.changed == ["tab_1", "pane_1"])
        // Hidden through a change that adds a place: the whole list when it shows.
        owed.note(renamed: nil)
        #expect(owed == .wholeList)
        owed.note(renamed: [tab])
        #expect(owed == .wholeList)
    }

    @Test func pastMostChangedThePageGetsTheWholeList() {
        var owed = AgentPaneLinkPlacesOwed.current
        let many = (0...AgentPaneLinkPlacesOwed.mostChanged).map { AgentPaneLinkPlaces.Place(id: "tab_\($0)", kind: .tab, title: "t") }
        owed.note(renamed: Array(many.dropLast()))
        #expect(!owed.whole)
        owed.note(renamed: [many.last!])
        #expect(owed == .wholeList)
    }

    /// Through the App's path: a rename in a 1,000-workspace session names the renamed places, as the
    /// list holds them now, and the list is the same as a fresh one.
    @Test func aTitleChangeInALargeSessionSendsOnlyThatTab() async throws {
        let count: UInt64 = 1_000
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(snapshot: DaemonTree(workspaces: (1...count).map { id in
            let tab = TabSnapshot(surface: SurfaceID(rawValue: id), tabResourceID: ResourceID(rawValue: "tab_\(id)"), kind: .pty, title: "shell \(id)")
            let pane = PaneSnapshot(id: PaneID(rawValue: id), resourceID: ResourceID(rawValue: "pane_\(id)"), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, resourceID: ResourceID(rawValue: "ws_\(id)"),
                                     name: "w\(id)", screens: [screen])
        }))
        let places = AgentPaneLinkPlaces()
        places.follow({ [store] in store.workspaces.map { ($0, host: nil) } }, titles: .records)
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        await until { places.places.count == Int(count) * 3 }
        #expect(places.places.count == Int(count) * 3)
        #expect(places.changedPlaces(["tab_7"])?.map(\.title) == ["shell 7"])

        store.apply(.titleChanged(surface: 7, title: "⠹ Working"))
        await until { places.changedPlaces(["tab_7"])?.first?.title == "⠹ Working" }
        let sent = try #require(places.changedPlaces(["tab_7", "pane_7"]))
        #expect(Set(sent.map(\.id)) == ["tab_7", "pane_7"])
        #expect(sent.allSatisfy { $0.title == "⠹ Working" })
        #expect(places.places.first { $0.id == "tab_7" }?.title == "⠹ Working")
        #expect(places.places.count == Int(count) * 3)
    }
}
