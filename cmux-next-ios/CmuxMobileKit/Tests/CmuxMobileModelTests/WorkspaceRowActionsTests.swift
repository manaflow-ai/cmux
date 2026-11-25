import Foundation
import Testing
@testable import CmuxMobileModel

/// The workspace-rows parity batch in the creator (verify/parity-mac.md, Workspaces): where New
/// Workspace Above / Below / at Top / in Group puts the new row, New Workspace Group, Duplicate
/// Workspace Group, Merge Workspace Into…, and the icon picker's symbol catalog.
@MainActor
@Suite struct WorkspaceRowActionsTests {
    typealias Recorder = WorkspaceGroupCreatorTests.Recorder
    let red = MacWorkspaceGroup(id: "grp_r", name: "Red", color: "red")

    /// Mac rows a (loose), b and c (group Red), in that order.
    private func setup() -> (AppStore, WorkspaceCreator, Recorder, String) {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mac = store.activeTeam!.macs.first { $0.isOnline }!
        store.workspaces = ["a", "b", "c"].enumerated().map { index, id in
            var ws = Workspace(id: id, macID: mac.id, title: id.uppercased(), directory: "~", tabs: [], lastActivityAt: Date())
            ws.sidebarIndex = index
            if id != "a" { ws.group = red }
            return ws
        }
        let recorder = Recorder()
        recorder.known = [red, MacWorkspaceGroup(id: "grp_g", name: "Green", color: "green")]
        let defaults = UserDefaults(suiteName: "rows-\(UUID().uuidString)")!
        return (store, WorkspaceCreator(store: store, backend: recorder, defaults: defaults), recorder, mac.id)
    }

    private func ws(_ store: AppStore, _ id: String) -> Workspace { store.workspaces.first { $0.id == id }! }

    @Test func aRowOffersAboveBelowTopAndBottom() {
        let (store, creator, _, _) = setup()
        #expect(creator.newWorkspacePlacements(beside: ws(store, "b")) == [.above("b"), .below("b"), .top, .bottom])
        #expect(NewWorkspacePlacement.below("b").title == "New Workspace Below")
        #expect(NewWorkspacePlacement.inGroup(red).title == "New Workspace in Group")
    }

    /// Below a grouped row: into its group first, then right after it in the person's order.
    @Test func newWorkspaceBelowAGroupedRowJoinsItsGroupNextToIt() async throws {
        let (_, creator, recorder, macID) = setup()
        let made = try #require(creator.create(macID: macID, placement: .below("b")))
        await creator.settle()
        #expect(recorder.calls == ["place \(made.id) grp_r"])
        #expect(recorder.moves == ["\(made.id) after b"])
    }

    @Test func newWorkspaceAboveALooseRowStaysLoose() async throws {
        let (_, creator, recorder, macID) = setup()
        let made = try #require(creator.create(macID: macID, placement: .above("a")))
        await creator.settle()
        #expect(recorder.calls.isEmpty)
        #expect(recorder.moves == ["\(made.id) before a"])
    }

    @Test func newWorkspaceAtTopAndBottomGoNextToTheFirstAndLastRows() async throws {
        let (_, creator, recorder, macID) = setup()
        let top = try #require(creator.create(macID: macID, placement: .top))
        await creator.settle()
        #expect(recorder.moves == ["\(top.id) before a"])
        let (_, other, otherRecorder, otherMac) = setup()
        let bottom = try #require(other.create(macID: otherMac, placement: .bottom))
        await other.settle()
        #expect(otherRecorder.moves == ["\(bottom.id) after c"])
    }

    @Test func newWorkspaceInGroupPlacesItInTheGroup() async throws {
        let (_, creator, recorder, macID) = setup()
        let made = try #require(creator.create(macID: macID, placement: .inGroup(red)))
        await creator.settle()
        #expect(recorder.calls == ["place \(made.id) grp_r"])
        #expect(recorder.moves.isEmpty)
    }

    @Test func newWorkspaceGroupMakesAnEmptyGroupInTheNextColor() async {
        let (_, creator, recorder, macID) = setup()
        creator.newGroup(on: macID, name: "  Backend ")
        creator.newGroup(on: macID, name: "")
        await creator.settle()
        // Red and green are taken: the Mac's next color is yellow (the mock lists no new group).
        #expect(recorder.calls == ["create Backend yellow", "create New Group yellow"])
        #expect(creator.groupsRevision == 2)
        // Green has no workspace on this phone: the list shows it as an empty group.
        #expect(creator.emptyGroups(on: macID).map(\.id) == ["grp_g"])
    }

    @Test func aRefusedNewGroupSaysSo() async {
        let (_, creator, recorder, macID) = setup()
        var failures: [String] = []
        creator.onGroupFailure = { _, what, _ in failures.append(what) }
        recorder.fail = "no"
        creator.newGroup(on: macID, name: "Backend")
        await creator.settle()
        #expect(failures == ["Couldn't make the group Backend"])
    }

    /// The same name and color, each member duplicated in order and placed in the copy.
    @Test func duplicateWorkspaceGroupCopiesEveryMemberIntoANewGroup() async {
        let (_, creator, recorder, macID) = setup()
        creator.duplicateGroup(red, on: macID)
        await creator.settle()
        #expect(recorder.calls == ["create Red red", "duplicate b", "place b-copy grp_new", "duplicate c", "place c-copy grp_new"])
    }

    @Test func edgeAnchorsSkipPinnedRowsAndHome() {
        func row(_ id: String, _ index: Int, pinned: Bool = false) -> Workspace {
            var ws = Workspace(id: id, macID: "m", title: id, directory: "~", tabs: [], lastActivityAt: Date())
            ws.sidebarIndex = index
            ws.isPinned = pinned
            return ws
        }
        var grouped = row("g", 1)
        grouped.group = MacWorkspaceGroup(id: "grp", name: "G")
        let rows = [row("p", 0, pinned: true), grouped, row("x", 2), row("y", 3), row("new", 4)]
        // Top skips the grouped first row; bottom is the last row.
        #expect(WorkspaceCreator.edgeAnchor(true, of: rows[4], in: rows)?.id == "x")
        #expect(WorkspaceCreator.edgeAnchor(false, of: rows[4], in: rows)?.id == "y")
        #expect(WorkspaceCreator.edgeAnchor(true, of: rows[4], in: [rows[4]]) == nil)
    }

    // MARK: The icon picker's catalog

    @Test func theSymbolCatalogReadsTheSystemsNamesInItsOrderWithKeywords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glyphs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ value: Any) throws {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                .write(to: folder.appendingPathComponent("\(name).plist"))
        }
        try write("symbol_order", ["star", "heart", "Bad Name", "folder"])
        try write("name_availability", ["symbols": ["star": "2019", "heart": "2019", "heart.fill": "2019", "folder": "2019", "trash": "2019"]])
        try write("symbol_search", ["heart": ["love", "like"], "folder": ["directory"]])
        let catalog = WorkspaceSymbolCatalog.read { name in
            let url = folder.appendingPathComponent("\(name).plist")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        // The system's order first, then the rest by name; an invalid name never shows.
        #expect(catalog.names == ["star", "heart", "folder", "heart.fill", "trash"])
        // A name takes its nearest dotted prefix's keywords.
        #expect(catalog.keywords[3] == "love like")
        #expect(catalog.search("love") == ["heart", "heart.fill"])
        #expect(catalog.search("dir") == ["folder"])
        #expect(catalog.search("tr") == ["trash"])
        #expect(catalog.search("") == catalog.names)
        #expect(WorkspaceSymbolCatalog.read { _ in nil } == .empty)
    }

    @Test func symbolNamesAreTheDaemonsShape() {
        #expect(WorkspaceIcon.isSymbolName("heart.fill"))
        #expect(!WorkspaceIcon.isSymbolName("Heart"))
        #expect(!WorkspaceIcon.isSymbolName("heart..fill"))
        #expect(!WorkspaceIcon.isSymbolName(".heart"))
    }
}

/// Merge Workspace Into…: each tab moves into the destination in order, never into Home.
@MainActor
@Suite struct WorkspaceMergeTests {
    final class Mover: WorkspaceCreationBackend {
        var moves: [String] = []
        func canCreate(on macID: String) -> Bool { true }
        func options(on macID: String) -> WorkspaceCreationOptions { .basic }
        func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
        func canManage(on macID: String) -> Bool { true }
        func canEditTabs(on macID: String) -> Bool { true }
        /// The source's panes after the moves (nil: the Mac lists it with no layout).
        var after: WorkspaceLayout?
        weak var store: AppStore?
        func moveTab(_ tab: WorkspaceTab, from workspace: Workspace, toWorkspace destination: Workspace?) async throws -> Workspace? {
            moves.append("\(tab.id) \(workspace.id) -> \(destination?.id ?? "new")")
            let layout = after
            store?.updateWorkspace(workspace.id) { ws in
                ws.tabs.removeAll { $0.id == tab.id }
                ws.layout = layout
            }
            return destination
        }
        func close(_ workspace: Workspace) async throws { moves.append("close \(workspace.id)") }
    }

    private func merging(after: WorkspaceLayout?) async -> [String] {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mac = store.activeTeam!.macs.first { $0.isOnline }!
        let tabs = ["s1", "s2"].map { WorkspaceTab(id: $0, kind: .terminal, title: $0) }
        let source = Workspace(id: "src", macID: mac.id, title: "Source", directory: "~", tabs: tabs, lastActivityAt: Date())
        let into = Workspace(id: "dst", macID: mac.id, title: "Dest", directory: "~", tabs: [], lastActivityAt: Date())
        store.workspaces = [source, into]
        let mover = Mover()
        mover.store = store
        mover.after = after
        let creator = WorkspaceCreator(store: store, backend: mover, defaults: UserDefaults(suiteName: "merge-\(UUID().uuidString)")!)
        creator.merge(source, into: into)
        await creator.settle()
        return mover.moves
    }

    /// The Mac reports no tab left: the emptied source closes, as on the Mac.
    @Test func anEmptiedSourceCloses() async {
        let empty = WorkspaceLayout(screens: [.init(id: 1, isActive: true, panes: [.init(id: 1, tabIDs: [], tabCount: 0)], root: .pane(1))])
        #expect(await merging(after: empty).last == "close src")
    }

    /// A tab the phone does not list stays on the Mac: the source stays open; so does one with no layout.
    @Test func aSourceWithUnlistedTabsStaysOpen() async {
        let unlisted = WorkspaceLayout(screens: [.init(id: 1, isActive: true, panes: [.init(id: 1, tabIDs: [], tabCount: 1)], root: .pane(1))])
        #expect(!(await merging(after: unlisted)).contains("close src"))
        #expect(!(await merging(after: nil)).contains("close src"))
    }

    @Test func mergeMovesEveryTabIntoTheDestinationInOrder() async {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mac = store.activeTeam!.macs.first { $0.isOnline }!
        let tabs = ["s1", "s2", "s3"].map { WorkspaceTab(id: $0, kind: .terminal, title: $0) }
        let source = Workspace(id: "src", macID: mac.id, title: "Source", directory: "~", tabs: tabs, lastActivityAt: Date())
        let into = Workspace(id: "dst", macID: mac.id, title: "Dest", directory: "~", tabs: [], lastActivityAt: Date())
        store.workspaces = [source, into]
        let mover = Mover()
        let creator = WorkspaceCreator(store: store, backend: mover, defaults: UserDefaults(suiteName: "merge-\(UUID().uuidString)")!)
        #expect(creator.mergeTargets(for: source).map(\.id) == ["dst"])
        // Nothing to move out of an empty workspace.
        #expect(creator.mergeTargets(for: into).isEmpty)
        creator.merge(source, into: into)
        await creator.settle()
        #expect(mover.moves == ["s1 src -> dst", "s2 src -> dst", "s3 src -> dst"])
    }
}
