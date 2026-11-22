import Foundation
import Testing
@testable import CmuxMobileModel

/// Parity round 2: the Mac's workspace pin, color, order, read marks and bulk
/// close on the phone (verify/parity-mac.md, Workspaces).
@Suite struct SidebarArrangementTests {
    private func workspaces(_ ids: [String], resource: Bool = true) -> [Workspace] {
        ids.map { id in
            var ws = Workspace(id: id, macID: "m", title: id, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 0))
            if resource { ws.resourceID = "ws_\(id)" }
            return ws
        }
    }

    @Test func parsesPersonalRowsAndPinnedTiles() {
        let personal: [String: Any] = ["ok": true, "data": ["workspaces": [
            ["session_id": "reg", "workspace_key": "b", "index": 0],
            ["session_id": "reg", "workspace_key": "a", "index": 1],
            ["session_id": "other", "workspace_key": "x"],
        ]]]
        #expect(SidebarArrangement.rows(personal: personal) == [
            .init(session: "reg", key: "b", index: 0), .init(session: "reg", key: "a", index: 1), .init(session: "other", key: "x", index: 0),
        ])
        #expect(SidebarArrangement.rows(personal: ["ok": true, "data": [:]]) == nil)
        let layout: [String: Any] = ["ok": true, "result": ["revision": "3", "sections": [
            ["id": "sec_top", "items": [["id": "itm_home", "ref": ["kind": "app", "value": "cmux/home"]]]],
            ["id": "sec_pinned", "items": [
                ["id": "itm_aaaaaaaaaaaaaaaa", "ref": ["kind": "workspace", "value": "reg:ws_c"]],
                ["id": "itm_bbbbbbbbbbbbbbbb", "ref": ["kind": "app", "value": "cmux/x"]],
                ["id": "itm_cccccccccccccccc", "ref": ["kind": "workspace", "value": "reg:ws_a"]],
            ]],
        ]]]
        #expect(SidebarArrangement.pins(layout: layout) == [
            .init(itemID: "itm_aaaaaaaaaaaaaaaa", value: "reg:ws_c"), .init(itemID: "itm_cccccccccccccccc", value: "reg:ws_a"),
        ])
        // A layout without a pinned section: nothing pinned (not "unknown").
        #expect(SidebarArrangement.pins(layout: ["result": ["sections": []]]) == [])
        #expect(SidebarArrangement.pins(layout: ["ok": false]) == nil)
    }

    /// The Mac's order: personal rows by place, the rest after in daemon order;
    /// pins are the tiles of this session's workspaces, in tile order.
    @Test func appliesTheMacsOrderAndPins() {
        var list = workspaces(["a", "b", "c", "d"])
        let arrangement = SidebarArrangement(
            rows: [.init(session: "reg", key: "c", index: 0), .init(session: "other", key: "z", index: 1), .init(session: "reg", key: "a", index: 2)],
            pins: [.init(itemID: "itm_1", value: "reg:ws_d"), .init(itemID: "itm_2", value: "other:ws_b")])
        arrangement.apply(to: &list, registryID: "reg", legacyPinned: ["b"])
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        #expect(byID["c"]?.sidebarIndex == 0)
        #expect(byID["a"]?.sidebarIndex == 2)
        // No personal row: after every row, in the daemon's order.
        #expect(byID["b"]?.sidebarIndex == 3 + 1)
        #expect(byID["d"]?.sidebarIndex == 3 + 3)
        #expect(byID["d"]?.isPinned == true && byID["d"]?.pinIndex == 0 && byID["d"]?.pinItemID == "itm_1")
        // Another session's tile is not this workspace's; the legacy flag still shows it pinned
        // until the Mac turns it into a tile.
        #expect(byID["b"]?.isPinned == true && byID["b"]?.pinItemID == nil)
        #expect(byID["a"]?.isPinned == false && byID["c"]?.isPinned == false)
    }

    /// An older Mac: the daemon's order and its pin flags.
    @Test func olderMacUsesTheDaemonOrderAndFlags() {
        var list = workspaces(["a", "b", "c"], resource: false)
        SidebarArrangement().apply(to: &list, registryID: nil, legacyPinned: ["c"])
        #expect(list.map(\.sidebarIndex) == [0, 1, 2])
        #expect(list.map(\.isPinned) == [false, false, true])
    }

    /// Move Workspace Up / Down: the Mac's `movePersonalWorkspace` index.
    @Test func personalIndexNextToTheNeighbour() {
        let rows: [SidebarArrangement.Row] = [
            .init(session: "reg", key: "a", index: 0), .init(session: "reg", key: "b", index: 1),
            .init(session: "x", key: "z", index: 2), .init(session: "reg", key: "c", index: 3),
        ]
        let arrangement = SidebarArrangement(rows: rows)
        let visible = workspaces(["a", "b", "c"])
        // b up: before a (index 0); b down: after c, whose place without b is 2 → 3.
        #expect(arrangement.personalIndex(moving: visible[1], by: -1, among: visible, registryID: "reg") == 0)
        #expect(arrangement.personalIndex(moving: visible[1], by: 1, among: visible, registryID: "reg") == 3)
        #expect(arrangement.personalIndex(moving: visible[0], by: -1, among: visible, registryID: "reg") == nil)
        #expect(arrangement.personalIndex(moving: visible[2], by: 1, among: visible, registryID: "reg") == nil)
        #expect(SidebarArrangement().personalIndex(moving: visible[1], by: -1, among: visible, registryID: "reg") == nil)
    }

    @Test func bulkCloseTargets() {
        let order = workspaces(["a", "b", "c", "d"])
        #expect(WorkspaceBulkClose.others.targets(of: order[1], in: order).map(\.id) == ["a", "c", "d"])
        #expect(WorkspaceBulkClose.above.targets(of: order[1], in: order).map(\.id) == ["a"])
        #expect(WorkspaceBulkClose.below.targets(of: order[1], in: order).map(\.id) == ["c", "d"])
        #expect(WorkspaceBulkClose.above.targets(of: order[0], in: order).isEmpty)
        #expect(WorkspaceBulkClose.others.title == "Close Other Workspaces")
        #expect(WorkspaceBulkClose.above.title == "Close Workspaces Above")
        #expect(WorkspaceBulkClose.below.title == "Close Workspaces Below")
        #expect(WorkspaceBulkClose.question(1) == "Close 1 workspace?")
        #expect(WorkspaceBulkClose.question(3) == "Close 3 workspaces?")
    }

    /// Close Other Workspaces in Group and Close All Workspaces; Home never closes.
    @Test func groupAndAllCloseTargets() {
        var order = workspaces(["home", "a", "b", "c"])
        order[0].isHome = true
        let group = MacWorkspaceGroup(id: "g", name: "G")
        order[1].group = group
        order[2].group = group
        #expect(WorkspaceBulkClose.othersInGroup.targets(of: order[1], in: order).map(\.id) == ["b"])
        #expect(WorkspaceBulkClose.othersInGroup.targets(of: order[3], in: order).isEmpty)
        #expect(WorkspaceBulkClose.all.targets(of: order[2], in: order).map(\.id) == ["a", "b", "c"])
        #expect(WorkspaceBulkClose.all.targets(of: order[0], in: order).map(\.id) == ["a", "b", "c"])
        #expect(WorkspaceBulkClose.others.targets(of: order[1], in: order).map(\.id) == ["b", "c"])
        // Home's own row keeps Close Other Workspaces and Below; Home itself never closes.
        #expect(WorkspaceBulkClose.others.targets(of: order[0], in: order).map(\.id) == ["a", "b", "c"])
        #expect(WorkspaceBulkClose.below.targets(of: order[0], in: order).map(\.id) == ["a", "b", "c"])
        #expect(WorkspaceBulkClose.above.targets(of: order[2], in: order).map(\.id) == ["a"])
        #expect(WorkspaceBulkClose.othersInGroup.title == "Close Other Workspaces in Group")
        #expect(WorkspaceBulkClose.all.title == "Close All Workspaces")
    }

    /// Move Workspace to Top / to Bottom and Sort: the index right before or after the anchor
    /// in the person's order without the moved workspace.
    @Test func personalIndexNextToAnAnchor() {
        let arrangement = SidebarArrangement(rows: [
            .init(session: "reg", key: "a", index: 0), .init(session: "x", key: "z", index: 1),
            .init(session: "reg", key: "b", index: 2), .init(session: "reg", key: "c", index: 3),
        ])
        let list = workspaces(["a", "b", "c"])
        // c before a: 0; a after c: without a, c is at 2 → 3; b before a: 0.
        #expect(arrangement.personalIndex(placing: list[2], next: list[0], after: false, registryID: "reg") == 0)
        #expect(arrangement.personalIndex(placing: list[0], next: list[2], after: true, registryID: "reg") == 3)
        #expect(arrangement.personalIndex(placing: list[1], next: list[0], after: false, registryID: "reg") == 0)
        #expect(arrangement.personalIndex(placing: list[1], next: list[1], after: false, registryID: "reg") == nil)
        // A workspace with no personal row yet still goes next to an anchor that has one.
        var fresh = list[0]
        fresh = Workspace(id: "n", macID: "m", title: "n", directory: "~", tabs: [], lastActivityAt: fresh.lastActivityAt)
        #expect(arrangement.personalIndex(placing: fresh, next: list[0], after: false, registryID: "reg") == 0)
        #expect(SidebarArrangement().personalIndex(placing: list[1], next: list[0], after: false, registryID: "reg") == nil)
    }

    @Test func edgesOfTheContainer() {
        let order = workspaces(["a", "b", "c"])
        #expect(WorkspaceEdge.top.anchor(of: order[2], in: order).map { "\($0.anchor.id) \($0.after)" } == "a false")
        #expect(WorkspaceEdge.bottom.anchor(of: order[0], in: order).map { "\($0.anchor.id) \($0.after)" } == "c true")
        #expect(WorkspaceEdge.top.anchor(of: order[0], in: order) == nil)
        #expect(WorkspaceEdge.bottom.anchor(of: order[2], in: order) == nil)
        #expect(WorkspaceEdge.top.title(grouped: false) == "Move Workspace to Top")
        #expect(WorkspaceEdge.bottom.title(grouped: true) == "Move to Bottom of Group")
    }

    /// The Mac's `WorkspaceSortKey`: Finder name order, folder then name, most recent first.
    @Test func sortKeysOrderAsTheMac() {
        var list = workspaces(["b10", "a", "b2", "c"])
        list[0].directory = "~/z"; list[1].directory = "~/y"; list[2].directory = "~/y"; list[3].directory = ""
        list[0].focusOrder = 1; list[1].focusOrder = 4; list[2].focusOrder = 9; list[3].focusOrder = 2
        #expect(WorkspaceSortKey.name.sorted(list).map(\.id) == ["a", "b2", "b10", "c"])
        #expect(WorkspaceSortKey.directory.sorted(list).map(\.id) == ["a", "b2", "b10", "c"])
        #expect(WorkspaceSortKey.lastUsed.sorted(list).map(\.id) == ["b2", "a", "c", "b10"])
        #expect(WorkspaceSortKey.allCases.map(\.title) == ["Sort Workspaces by Name", "Sort Workspaces by Last Used", "Sort Workspaces by Directory"])
    }

    /// One row at a time: the first before the container's first row, each next after the one before.
    @Test func sortStepsMoveOnlyWhatIsOutOfPlace() {
        let list = workspaces(["c", "a", "b"])
        let steps = WorkspaceSortKey.steps(from: list, to: WorkspaceSortKey.name.sorted(list))
        #expect(steps.map { "\($0.workspace.id) \($0.after ? "after" : "before") \($0.anchor.id)" } == ["a before c", "b after a"])
        #expect(WorkspaceSortKey.steps(from: list, to: list).isEmpty)
    }

    @Test func colorsAreTheMacPalette() {
        #expect(WorkspaceColor.allCases.map(\.title) == ["Grey", "Blue", "Red", "Yellow", "Green", "Pink", "Purple", "Cyan", "Orange"])
        #expect(WorkspaceColor(stored: "Blue") == .blue)
        #expect(WorkspaceColor(stored: "#112233") == nil)
        #expect(WorkspaceColor(stored: nil) == nil)
    }
}

/// New Workspace › Open Folder…: a typed full path, with the same rules as the typed `cd`.
@Suite struct WorkspaceIconTests {
    @Test func oneEmojiOnly() {
        #expect(WorkspaceIcon.emoji(" 🚀 ") == "🚀")
        #expect(WorkspaceIcon.emoji("👩‍💻") == "👩‍💻")
        #expect(WorkspaceIcon.emoji("🚀🚀") == nil)
        #expect(WorkspaceIcon.emoji("a") == nil)
        #expect(WorkspaceIcon.emoji("1") == nil)
        #expect(WorkspaceIcon.emoji("") == nil)
    }
}

@Suite struct WorkspaceFolderPathTests {
    @Test func acceptsFullPaths() {
        #expect(WorkspaceFolderPath("  ~/code/app/ ")?.path == "~/code/app")
        #expect(WorkspaceFolderPath("/Users/me/x")?.refusal(macName: "Mac") == nil)
        #expect(WorkspaceFolderPath("~")?.refusal(macName: "Mac") == nil)
        #expect(WorkspaceFolderPath("/")?.path == "/")
        #expect(WorkspaceFolderPath("   ") == nil)
    }

    @Test func refusesRelativeAndUntypableFolders() {
        #expect(WorkspaceFolderPath("code/app")?.refusal(macName: "Studio") == "Type the folder's full path on Studio, starting with / or ~/.")
        for path in ["/tmp/bang!", "/tmp/a\\b", "/tmp/a\u{7f}b", "/tmp/a\u{15}b", "~/a\u{200b}b"] {
            #expect(WorkspaceFolderPath(path)?.refusal(macName: "Studio")?.contains("Open it in cmux on Studio") == true, "\(path.debugDescription)")
        }
    }
}

/// The creator's arrangement actions: at once on the phone, undone when the Mac refuses.
@MainActor
@Suite struct WorkspaceArrangeCreatorTests {
    final class Recorder: WorkspaceCreationBackend, WorkspaceArrangementBackend {
        var calls: [String] = []
        var fail: String?
        func canCreate(on macID: String) -> Bool { true }
        func options(on macID: String) -> WorkspaceCreationOptions { .basic }
        func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
        func canManage(on macID: String) -> Bool { true }
        func close(_ workspace: Workspace) async throws { calls.append("close \(workspace.id)") }
        func canArrange(on macID: String) -> Bool { true }
        private func record(_ call: String) throws {
            calls.append(call)
            if let fail { throw WorkspaceCreationError(fail) }
        }
        func setPinned(_ workspace: Workspace, _ pinned: Bool) async throws { try record("pin \(workspace.id) \(pinned)") }
        func setColor(_ workspace: Workspace, _ color: WorkspaceColor?) async throws { try record("color \(workspace.id) \(color?.rawValue ?? "nil")") }
        func move(_ workspace: Workspace, by offset: Int, among visible: [Workspace]) async throws {
            try record("move \(workspace.id) \(offset) \(visible.map(\.id).joined(separator: ","))")
        }
        func setUnread(_ workspace: Workspace, _ unread: Bool) async throws { try record("unread \(workspace.id) \(unread)") }
        func setIcon(_ workspace: Workspace, _ icon: String?) async throws { try record("icon \(workspace.id) \(icon ?? "nil")") }
        func clearName(_ workspace: Workspace) async throws { try record("clearName \(workspace.id)") }
        func place(_ workspace: Workspace, next anchor: Workspace, after: Bool) async throws {
            try record("place \(workspace.id) \(after ? "after" : "before") \(anchor.id)")
        }
    }

    private func setup() -> (AppStore, WorkspaceCreator, Recorder) {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mac = store.activeTeam!.macs.first { $0.isOnline }!
        store.workspaces = ["a", "b", "c"].enumerated().map { index, id in
            var ws = Workspace(id: id, macID: mac.id, title: id.uppercased(), directory: "~", tabs: [], lastActivityAt: Date())
            ws.sidebarIndex = index
            return ws
        }
        let recorder = Recorder()
        let defaults = UserDefaults(suiteName: "arrange-\(UUID().uuidString)")!
        return (store, WorkspaceCreator(store: store, backend: recorder, defaults: defaults), recorder)
    }

    @Test func pinColorAndUnreadApplyAtOnce() async {
        let (store, creator, recorder) = setup()
        let a = store.workspaces[0]
        creator.setPinned(a, true)
        #expect(store.workspaces[0].isPinned)
        creator.setColor(store.workspaces[0], .green)
        #expect(store.workspaces[0].colorHex == "green")
        creator.setUnread(store.workspaces[0], true)
        #expect(store.workspaces[0].hasUnread)
        await creator.settle()
        #expect(recorder.calls == ["pin a true", "color a green", "unread a true"])
    }

    @Test func aRefusalUndoesTheChange() async {
        let (store, creator, recorder) = setup()
        recorder.fail = "no"
        var failures: [String] = []
        creator.onManageFailure = { _, what, why in failures.append("\(what): \(why)") }
        creator.setColor(store.workspaces[1], .red)
        #expect(store.workspaces[1].colorHex == "red")
        await creator.settle()
        #expect(store.workspaces[1].colorHex == nil)
        #expect(failures == ["Couldn't change the color of B: no"])
    }

    @Test func moveSwapsPlacesAndRollsBack() async {
        let (store, creator, recorder) = setup()
        let order = store.workspaces
        creator.move(order[1], by: -1, among: order)
        #expect(store.workspaces.first { $0.id == "b" }?.sidebarIndex == 0)
        #expect(store.workspaces.first { $0.id == "a" }?.sidebarIndex == 1)
        await creator.settle()
        #expect(recorder.calls == ["move b -1 a,b,c"])
        // At the top: nothing to do.
        creator.move(order[0], by: -1, among: order)
        await creator.settle()
        #expect(recorder.calls.count == 1)
        recorder.fail = "busy"
        creator.move(order[2], by: -1, among: order)
        await creator.settle()
        #expect(store.workspaces.first { $0.id == "c" }?.sidebarIndex == 2)
    }

    @Test func iconAndClearName() async {
        let (store, creator, recorder) = setup()
        creator.setIcon(store.workspaces[0], "hammer")
        #expect(store.workspaces[0].icon == "hammer")
        creator.setIcon(store.workspaces[0], nil)
        #expect(store.workspaces[0].icon == nil)
        // Only a workspace with a display name over its own name.
        creator.clearName(store.workspaces[1])
        store.updateWorkspace("c") { $0.hasCustomTitle = true }
        creator.clearName(store.workspaces[2])
        #expect(!store.workspaces[2].hasCustomTitle)
        await creator.settle()
        #expect(recorder.calls == ["icon a hammer", "icon a nil", "clearName c"])
    }

    @Test func moveToTopAndBottomOfTheLooseRows() async {
        let (store, creator, recorder) = setup()
        creator.move(store.workspaces[2], to: .top)
        #expect(store.workspaces.sorted { $0.sidebarIndex! < $1.sidebarIndex! }.map(\.id) == ["c", "a", "b"])
        await creator.settle()
        creator.move(store.workspaces.first { $0.id == "a" }!, to: .bottom)
        await creator.settle()
        #expect(recorder.calls == ["place c before a", "place a after b"])
        #expect(store.workspaces.sorted { $0.sidebarIndex! < $1.sidebarIndex! }.map(\.id) == ["c", "b", "a"])
        // A refusal puts every row back.
        recorder.fail = "busy"
        creator.move(store.workspaces.first { $0.id == "a" }!, to: .top)
        await creator.settle()
        #expect(store.workspaces.sorted { $0.sidebarIndex! < $1.sidebarIndex! }.map(\.id) == ["c", "b", "a"])
    }

    @Test func sortEachContainerOnTheMac() async {
        let (store, creator, recorder) = setup()
        let mac = store.workspaces[0].macID
        store.updateWorkspace("a") { $0.title = "Zed" }
        creator.sortWorkspaces(on: mac, by: .name)
        #expect(store.workspaces.sorted { $0.sidebarIndex! < $1.sidebarIndex! }.map(\.id) == ["b", "c", "a"])
        await creator.settle()
        #expect(recorder.calls == ["place b before a", "place c after b"])
        // Already sorted: nothing to send.
        creator.sortWorkspaces(on: mac, by: .name)
        await creator.settle()
        #expect(recorder.calls.count == 2)
    }

    @Test func removeAllColorsOnOneMac() async {
        let (store, creator, recorder) = setup()
        let mac = store.workspaces[0].macID
        store.updateWorkspace("a") { $0.colorHex = "red" }
        store.updateWorkspace("c") { $0.colorHex = "blue" }
        #expect(creator.hasColors(on: mac))
        creator.removeAllColors(on: mac)
        #expect(!creator.hasColors(on: mac))
        await creator.settle()
        #expect(recorder.calls == ["color a nil", "color c nil"])
    }

    @Test func aPinnedWorkspaceDoesNotMove() async {
        let (store, creator, recorder) = setup()
        store.updateWorkspace("b") { $0.isPinned = true }
        let order = store.workspaces
        creator.move(order[1], by: -1, among: order)
        await creator.settle()
        #expect(recorder.calls.isEmpty)
    }

    @Test func bulkCloseClosesEach() async {
        let (store, creator, recorder) = setup()
        let order = store.workspaces
        creator.close(WorkspaceBulkClose.others.targets(of: order[0], in: order))
        await creator.settle()
        #expect(Set(recorder.calls) == ["close b", "close c"])
        #expect(store.workspaces.map(\.id) == ["a"])
    }
}
