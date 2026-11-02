import Foundation
import Testing
@testable import CmuxMobileModel

/// Parity round 3: the Mac's workspace groups on the phone
/// (verify/parity-mac.md, Workspaces, "Workspace groups").
@Suite struct WorkspaceGroupArrangementTests {
    private func workspaces(_ ids: [String]) -> [Workspace] {
        ids.map { id in
            var ws = Workspace(id: id, macID: "m", title: id, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 0))
            ws.resourceID = "ws_\(id)"
            return ws
        }
    }

    static var personal: [String: Any] { ["ok": true, "data": [
        "groups": [
            ["id": "grp_b", "name": "Backend", "color": "red", "collapsed": true, "index": 1, "profile": "default"],
            ["id": "grp_a", "name": "", "color": "green", "index": 0, "top_index": 1, "profile": "work"],
        ],
        "workspaces": [
            ["session_id": "reg", "workspace_key": "a", "index": 0],
            ["session_id": "reg", "workspace_key": "b", "index": 1, "group": "grp_a"],
            ["session_id": "other", "workspace_key": "x", "index": 2, "group": "grp_b"],
            ["session_id": "reg", "workspace_key": "c", "index": 3, "group": "grp_b"],
            ["session_id": "reg", "workspace_key": "d", "index": 4],
        ],
        "profiles": [
            ["id": "default", "index": 0, "follows": []],
            ["id": "work", "index": 1, "follows": ["reg"]],
            ["id": "home", "index": 2, "follows": ["reg"]],
        ],
        "pins": [["session_id": "reg", "workspace_key": "d", "profile": "home"]],
    ]] }

    @Test func parsesGroupsRoomsAndPins() {
        let groups = SidebarArrangement.groups(personal: Self.personal)
        #expect(groups.map(\.id) == ["grp_b", "grp_a"])
        #expect(groups[0] == MacWorkspaceGroup(id: "grp_b", name: "Backend", color: "red", isCollapsed: true, index: 1, room: "default"))
        #expect(groups[1].topIndex == 1 && groups[1].displayName == "Unnamed Group")
        #expect(SidebarArrangement.rows(personal: Self.personal)?.map(\.group) == [nil, "grp_a", "grp_b", "grp_b", nil])
        #expect(SidebarArrangement.rooms(personal: Self.personal).map(\.id) == ["default", "work", "home"])
        #expect(SidebarArrangement.roomPins(personal: Self.personal) == [.init(session: "reg", key: "d", room: "home")])
        // An older Mac: no groups, rooms or pins.
        #expect(SidebarArrangement.groups(personal: ["ok": true, "data": [:]]).isEmpty)
    }

    private var arrangement: SidebarArrangement {
        SidebarArrangement(rows: SidebarArrangement.rows(personal: Self.personal), pins: [],
                           groups: SidebarArrangement.groups(personal: Self.personal),
                           rooms: SidebarArrangement.rooms(personal: Self.personal),
                           roomPins: SidebarArrangement.roomPins(personal: Self.personal))
    }

    /// The Mac's mixed order: grp_a (top_index 1) before row 1, then the loose rows,
    /// a workspace without a row, then grp_b (no top_index) at the end.
    @Test func appliesTheMacsGroupOrder() {
        var list = workspaces(["a", "b", "c", "d", "e"])
        arrangement.apply(to: &list, registryID: "reg", legacyPinned: [])
        let order = list.sorted { ($0.sidebarIndex ?? .max) < ($1.sidebarIndex ?? .max) }.map(\.id)
        #expect(order == ["a", "b", "d", "e", "c"])
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        #expect(byID["b"]?.group?.id == "grp_a")
        #expect(byID["c"]?.group?.id == "grp_b" && byID["c"]?.group?.isCollapsed == true)
        #expect(byID["a"]?.group == nil && byID["d"]?.group == nil && byID["e"]?.group == nil)
        // A group the Mac no longer has leaves the workspace loose; without groups, no group.
        var plain = workspaces(["a", "b"])
        SidebarArrangement(rows: arrangement.rows).apply(to: &plain, registryID: "reg", legacyPinned: [])
        #expect(plain.allSatisfy { $0.group == nil })
    }

    /// A phone may use only groups of this Mac's workspaces (or empty ones).
    @Test func ownGroupsLeaveOutAnotherMachinesGroup() {
        var withEmpty = arrangement
        withEmpty.groups.append(MacWorkspaceGroup(id: "grp_empty", name: "Empty", index: 2))
        #expect(withEmpty.ownGroups(registryID: "reg").map(\.id) == ["grp_a", "grp_empty"])
    }

    /// The room a new group goes to: the workspace's pin, else the first room that
    /// follows this session, else the default room.
    @Test func newGroupRoom() {
        #expect(arrangement.room(forWorkspace: "d", registryID: "reg") == "home")
        #expect(arrangement.room(forWorkspace: "a", registryID: "reg") == "work")
        #expect(arrangement.room(forWorkspace: "a", registryID: "elsewhere") == "default")
    }

    @Test func nextGroupColorIsTheMacs() {
        #expect(MacWorkspaceGroup.nextColor(used: []) == .red)
        #expect(MacWorkspaceGroup.nextColor(used: ["red", "green"]) == .yellow)
        #expect(MacWorkspaceGroup.nextColor(used: ["red", "green", "yellow", "purple", "cyan", "orange", "pink"]) == .grey)
    }

    @Test func groupSurvivesASavedSnapshot() throws {
        var ws = workspaces(["a"])[0]
        ws.group = MacWorkspaceGroup(id: "grp_a", name: "A", color: "red")
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        #expect(decoded.group == ws.group)
        // A snapshot saved before groups existed still loads.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspaces(["b"])[0])) as? [String: Any])
        object["group"] = nil
        #expect(try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object)).group == nil)
    }
}

/// The creator's group actions: at once on the phone, undone when the Mac refuses.
@MainActor
@Suite struct WorkspaceGroupCreatorTests {
    final class Recorder: WorkspaceCreationBackend, WorkspaceArrangementBackend, WorkspaceGroupBackend {
        var calls: [String] = []
        var fail: String?
        var known: [MacWorkspaceGroup] = []
        func canCreate(on macID: String) -> Bool { true }
        func options(on macID: String) -> WorkspaceCreationOptions { .basic }
        func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
        func canManage(on macID: String) -> Bool { true }
        func canArrange(on macID: String) -> Bool { true }
        private func record(_ call: String) throws {
            calls.append(call)
            if let fail { throw WorkspaceCreationError(fail) }
        }
        func setPinned(_ workspace: Workspace, _ pinned: Bool) async throws {}
        func setColor(_ workspace: Workspace, _ color: WorkspaceColor?) async throws {}
        func move(_ workspace: Workspace, by offset: Int, among visible: [Workspace]) async throws {}
        func setUnread(_ workspace: Workspace, _ unread: Bool) async throws {}
        func setIcon(_ workspace: Workspace, _ icon: String?) async throws {}
        func clearName(_ workspace: Workspace) async throws {}
        func place(_ workspace: Workspace, next anchor: Workspace, after: Bool) async throws {}
        func close(_ workspace: Workspace) async throws { try record("close \(workspace.id)") }
        func groups(on macID: String) -> [MacWorkspaceGroup] { known }
        func place(_ workspace: Workspace, in group: MacWorkspaceGroup?) async throws {
            try record("place \(workspace.id) \(group?.id ?? "nil")")
        }
        func moveToNewGroup(_ workspace: Workspace, name: String, color: WorkspaceColor) async throws {
            try record("new \(workspace.id) \(name) \(color.rawValue)")
        }
        /// Group updates wait here until a test resumes them (a Mac round trip in flight).
        var holds = false
        var held: [CheckedContinuation<Void, Never>] = []
        /// Only a collapse (true) or an expand (false) is refused.
        var refuseCollapsed: Bool?
        func updateGroup(_ group: MacWorkspaceGroup, on macID: String, name: String?, color: WorkspaceColor?, collapsed: Bool?) async throws {
            if holds { await withCheckedContinuation { held.append($0) } }
            if let refuseCollapsed, collapsed == refuseCollapsed {
                calls.append("refused \(group.id) \(refuseCollapsed)")
                throw WorkspaceCreationError("no")
            }
            try record("update \(group.id) \(name ?? "-") \(color?.rawValue ?? "-") \(collapsed.map(String.init) ?? "-")")
        }

        /// Waits until `count` updates are in flight.
        func waitHeld(_ count: Int) async {
            while held.count < count { await Task.yield() }
        }
        func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) async throws { try record("delete \(group.id)") }
    }

    let red = MacWorkspaceGroup(id: "grp_r", name: "Red", color: "red")

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
        let defaults = UserDefaults(suiteName: "groups-\(UUID().uuidString)")!
        return (store, WorkspaceCreator(store: store, backend: recorder, defaults: defaults), recorder, mac.id)
    }

    private func ws(_ store: AppStore, _ id: String) -> Workspace { store.workspaces.first { $0.id == id }! }

    /// Collapse Others, Collapse All Groups, Expand All Groups (the Mac's group Options).
    @Test func collapseOthersAllAndExpandAll() async {
        let (store, creator, recorder, mac) = setup()
        let green = MacWorkspaceGroup(id: "grp_g", name: "Green", color: "green")
        store.updateWorkspace("a") { $0.group = green }
        #expect(creator.shownGroups(on: mac).map(\.id) == ["grp_g", "grp_r"])
        creator.collapseOtherGroups(keeping: red, on: mac)
        #expect(ws(store, "a").group?.isCollapsed == true && ws(store, "b").group?.isCollapsed == false)
        #expect(!creator.canCollapseOthers(keeping: red, on: mac))
        creator.setAllGroupsCollapsed(on: mac, true)
        #expect(ws(store, "b").group?.isCollapsed == true && ws(store, "c").group?.isCollapsed == true)
        creator.setAllGroupsCollapsed(on: mac, false)
        await creator.settle()
        #expect(recorder.calls == ["update grp_g - - true", "update grp_r - - true", "update grp_g - - false", "update grp_r - - false"])
    }

    /// Close All in Group / Close Other Groups: a pinned group stays, folded; another goes; then
    /// its workspaces close.
    @Test func closingGroupsClosesTheirWorkspaces() async {
        let (store, creator, recorder, mac) = setup()
        var pinned = red
        pinned.isPinned = true
        for id in ["b", "c"] { store.updateWorkspace(id) { $0.group = pinned } }
        #expect(creator.members(of: [pinned], on: mac).map(\.id) == ["b", "c"])
        creator.closeGroups([pinned], on: mac)
        await creator.settle()
        #expect(recorder.calls == ["update grp_r - - true", "close b", "close c"])
        #expect(store.workspaces.map(\.id) == ["a"])
        let green = MacWorkspaceGroup(id: "grp_g", name: "Green", color: "green")
        store.updateWorkspace("a") { $0.group = green }
        recorder.calls = []
        creator.closeGroups([green], on: mac)
        await creator.settle()
        #expect(recorder.calls == ["delete grp_g", "close a"])
    }

    @Test func parsesThePinnedFlag() {
        let reply: [String: Any] = ["data": ["groups": [["id": "g1", "name": "A", "pinned": true], ["id": "g2", "name": "B"]]]]
        #expect(SidebarArrangement.groups(personal: reply).map(\.isPinned) == [true, nil])
    }

    @Test func moveAndRemoveApplyAtOnce() async {
        let (store, creator, recorder, _) = setup()
        // The choices leave out the workspace's own group.
        #expect(creator.groupChoices(for: ws(store, "b")).map(\.id) == ["grp_g"])
        #expect(creator.groupChoices(for: ws(store, "a")).map(\.id) == ["grp_r", "grp_g"])
        creator.place(ws(store, "a"), in: red)
        #expect(ws(store, "a").group?.id == "grp_r")
        creator.place(ws(store, "b"), in: nil)
        #expect(ws(store, "b").group == nil)
        // Already there: nothing to send.
        creator.place(ws(store, "c"), in: red)
        await creator.settle()
        #expect(recorder.calls == ["place a grp_r", "place b nil"])
    }

    @Test func aRefusedMoveComesBack() async {
        let (store, creator, recorder, _) = setup()
        recorder.fail = "no"
        var failures: [String] = []
        creator.onManageFailure = { _, what, why in failures.append("\(what): \(why)") }
        creator.place(ws(store, "b"), in: nil)
        await creator.settle()
        #expect(ws(store, "b").group?.id == "grp_r")
        #expect(failures == ["Couldn't remove B from its group: no"])
    }

    @Test func newGroupTakesTheNextColorAndADefaultName() async {
        let (store, creator, recorder, _) = setup()
        creator.moveToNewGroup(ws(store, "a"), name: "  ")
        #expect(ws(store, "a").group?.name == "New Group")
        #expect(ws(store, "a").group?.color == "yellow")
        creator.moveToNewGroup(ws(store, "b"), name: "Ship")
        await creator.settle()
        #expect(recorder.calls == ["new a New Group yellow", "new b Ship yellow"])
        recorder.fail = "no"
        creator.moveToNewGroup(ws(store, "c"), name: "x")
        await creator.settle()
        #expect(ws(store, "c").group?.id == "grp_r")
    }

    @Test func groupEditsChangeEveryMember() async {
        let (store, creator, recorder, mac) = setup()
        creator.renameGroup(red, on: mac, to: " Release ")
        #expect(ws(store, "b").group?.name == "Release" && ws(store, "c").group?.name == "Release")
        creator.setGroupColor(ws(store, "b").group!, on: mac, .cyan)
        #expect(ws(store, "c").group?.color == "cyan")
        creator.setGroupCollapsed(ws(store, "b").group!, on: mac, true)
        #expect(ws(store, "b").group?.isCollapsed == true)
        // Nothing to change: nothing sent.
        creator.renameGroup(red, on: mac, to: "  ")
        creator.setGroupColor(ws(store, "b").group!, on: mac, .cyan)
        await creator.settle()
        #expect(recorder.calls == ["update grp_r Release - -", "update grp_r - cyan -", "update grp_r - - true"])
        #expect(ws(store, "a").group == nil)
    }

    @Test func deleteKeepsTheWorkspacesAndRollsBack() async {
        let (store, creator, recorder, mac) = setup()
        recorder.fail = "busy"
        creator.deleteGroup(red, on: mac)
        #expect(ws(store, "b").group == nil && ws(store, "c").group == nil)
        #expect(store.workspaces.count == 3)
        await creator.settle()
        #expect(ws(store, "b").group?.id == "grp_r" && ws(store, "c").group?.id == "grp_r")
        recorder.fail = nil
        creator.deleteGroup(red, on: mac)
        await creator.settle()
        #expect(ws(store, "b").group == nil)
        #expect(recorder.calls == ["delete grp_r", "delete grp_r"])
    }

    /// What a background refresh publishes while the Mac's arrangement is
    /// still the cached one: every member with the group as it was.
    private func staleRefresh(_ store: AppStore, mac: String, collapsed: Bool = false) {
        var group = red
        group.isCollapsed = collapsed
        let rows = store.workspaces.filter { $0.macID == mac }.map { ws -> Workspace in
            var ws = ws
            if ws.id != "a" { ws.group = group }
            return ws
        }
        store.replaceWorkspaces(macID: mac, with: rows)
    }

    /// "Disclosure groups not being properly closable": a terminal title or
    /// agent event refreshes the list while the collapse is on its way to the
    /// Mac, from the arrangement cached before it; the group must stay closed.
    @Test func aRefreshDuringACollapseKeepsTheGroupClosed() async {
        let (store, creator, recorder, mac) = setup()
        recorder.holds = true
        creator.setGroupCollapsed(red, on: mac, true)
        await recorder.waitHeld(1)
        staleRefresh(store, mac: mac)
        #expect(ws(store, "b").group?.isCollapsed == true && ws(store, "c").group?.isCollapsed == true)
        recorder.held.removeFirst().resume()
        await creator.settle()
        // The Mac said yes, but a refresh can still carry the old arrangement.
        staleRefresh(store, mac: mac)
        #expect(ws(store, "b").group?.isCollapsed == true)
        // The Mac's list shows it closed: the edit is confirmed.
        staleRefresh(store, mac: mac, collapsed: true)
        #expect(ws(store, "b").group?.isCollapsed == true)
        // From then on the Mac's state wins (another device expanded it).
        staleRefresh(store, mac: mac, collapsed: false)
        #expect(ws(store, "b").group?.isCollapsed == false)
    }

    @Test func anUnconfirmedEditGivesWayToTheMacAfterAWhile() async {
        let (store, creator, _, mac) = setup()
        var now = Date(timeIntervalSince1970: 1_000)
        store.now = { now }
        creator.setGroupCollapsed(red, on: mac, true)
        await creator.settle()
        staleRefresh(store, mac: mac)
        #expect(ws(store, "b").group?.isCollapsed == true)
        now += 30
        staleRefresh(store, mac: mac)
        #expect(ws(store, "b").group?.isCollapsed == false)
    }

    /// Two quick taps: the second one is what shows, whatever the first one's answer.
    @Test func quickTapsEndOnTheLastTap() async {
        let (store, creator, recorder, mac) = setup()
        recorder.holds = true
        recorder.refuseCollapsed = true
        creator.setGroupCollapsed(red, on: mac, true)
        creator.setGroupCollapsed(ws(store, "b").group!, on: mac, false)
        #expect(ws(store, "b").group?.isCollapsed == false)
        // One request at a time: the expand waits for the collapse.
        await recorder.waitHeld(1)
        recorder.held.removeFirst().resume()
        await recorder.waitHeld(1)
        // The collapse was refused before the expand went: its rollback
        // must not undo the later tap.
        #expect(ws(store, "b").group?.isCollapsed == false)
        recorder.held.removeFirst().resume()
        await creator.settle()
        #expect(recorder.calls == ["refused grp_r true", "update grp_r - - false"])
        #expect(ws(store, "b").group?.isCollapsed == false && ws(store, "c").group?.isCollapsed == false)
        staleRefresh(store, mac: mac, collapsed: true)
        #expect(ws(store, "b").group?.isCollapsed == false)
    }

    /// Both taps accepted: the Mac gets them in tap order, so it ends where the phone does.
    @Test func quickTapsReachTheMacInOrder() async {
        let (store, creator, recorder, mac) = setup()
        recorder.holds = true
        creator.setGroupCollapsed(red, on: mac, true)
        creator.setGroupCollapsed(ws(store, "b").group!, on: mac, false)
        creator.setGroupCollapsed(ws(store, "b").group!, on: mac, true)
        for _ in 0..<3 {
            await recorder.waitHeld(1)
            #expect(recorder.held.count == 1)
            recorder.held.removeFirst().resume()
        }
        await creator.settle()
        #expect(recorder.calls == ["update grp_r - - true", "update grp_r - - false", "update grp_r - - true"])
        #expect(ws(store, "b").group?.isCollapsed == true)
    }

    @Test func anUnansweredEditGivesWayToTheMac() async {
        let (store, creator, recorder, mac) = setup()
        var now = Date(timeIntervalSince1970: 1_000)
        store.now = { now }
        recorder.holds = true
        creator.setGroupCollapsed(red, on: mac, true)
        await recorder.waitHeld(1)
        now += 5
        staleRefresh(store, mac: mac)
        #expect(ws(store, "b").group?.isCollapsed == true)
        now += 60
        staleRefresh(store, mac: mac)
        #expect(ws(store, "b").group?.isCollapsed == false)
        recorder.held.removeFirst().resume()
        await creator.settle()
    }

    /// A tap queued behind a slow request does not expire before it is sent.
    @Test func aQueuedEditWaitsForItsTurn() async {
        let (store, creator, recorder, mac) = setup()
        var now = Date(timeIntervalSince1970: 1_000)
        store.now = { now }
        recorder.holds = true
        creator.setGroupCollapsed(red, on: mac, true)
        creator.setGroupCollapsed(ws(store, "b").group!, on: mac, false)
        await recorder.waitHeld(1)
        now += 25
        recorder.held.removeFirst().resume()
        await recorder.waitHeld(1)
        // The expand left 25 s after its tap; 10 s later it still holds.
        now += 10
        staleRefresh(store, mac: mac, collapsed: true)
        #expect(ws(store, "b").group?.isCollapsed == false)
        recorder.held.removeFirst().resume()
        await creator.settle()
    }

    /// A new group replaces an earlier move: refreshes show the Mac's group, not the earlier one.
    @Test func aNewGroupSupersedesAnEarlierMove() async {
        let (store, creator, _, mac) = setup()
        let green = MacWorkspaceGroup(id: "grp_g", name: "Green", color: "green")
        creator.place(ws(store, "a"), in: green)
        await creator.settle()
        creator.moveToNewGroup(ws(store, "a"), name: "Fresh")
        await creator.settle()
        let made = MacWorkspaceGroup(id: "grp_new", name: "Fresh", color: "blue")
        let rows = store.workspaces.filter { $0.macID == mac }.map { ws -> Workspace in
            var ws = ws
            if ws.id == "a" { ws.group = made }
            return ws
        }
        store.replaceWorkspaces(macID: mac, with: rows)
        #expect(ws(store, "a").group?.id == "grp_new")
    }

    @Test func aRefusedCollapseOpensAgainAndARefreshKeepsIt() async {
        let (store, creator, recorder, mac) = setup()
        recorder.refuseCollapsed = true
        creator.setGroupCollapsed(red, on: mac, true)
        await creator.settle()
        #expect(ws(store, "b").group?.isCollapsed == false)
        staleRefresh(store, mac: mac)
        #expect(ws(store, "b").group?.isCollapsed == false)
    }

    @Test func aRefusedRenameComesBack() async {
        let (store, creator, recorder, mac) = setup()
        recorder.fail = "no"
        creator.renameGroup(red, on: mac, to: "Other")
        await creator.settle()
        #expect(ws(store, "b").group?.name == "Red" && ws(store, "c").group?.name == "Red")
    }
}
