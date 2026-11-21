import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// A busy Mac changes a few rows of a long list every frame (a spinner in a title, an agent
/// starting or stopping). The Workspaces inbox updated those rows alone? Before, every change of
/// the store built the whole inbox (filters, statuses, a sort and maps of every row): O(rows) on
/// the main thread per event, 500 rows read for one changed title (WS-10).
@MainActor
@Suite struct WorkspaceInboxPatchTests {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let macs = [
        MacDevice(id: "m1", name: "Mac Studio", isOnline: true),
        MacDevice(id: "m2", name: "MacBook Pro", isOnline: true),
        MacDevice(id: "m3", name: "Mac mini", isOnline: false),
    ]

    static func rows(_ count: Int, macOrder: Bool = false, macs: [String] = ["m1", "m2"]) -> [Workspace] {
        (0..<count).map { index in
            var ws = Workspace(id: "w\(index)", macID: macs[index % macs.count], title: "agent \(index)",
                               directory: "~/src/p\(index % 7)", tabs: [],
                               lastActivityAt: now.addingTimeInterval(-Double(index * 13 % 997)),
                               isWorking: index % 5 == 0, focusOrder: index % 3)
            if macOrder { ws.sidebarIndex = index / macs.count }
            return ws
        }
    }

    static func store(_ rows: [Workspace]) -> AppStore {
        let store = AppStore.mock(now: now)
        store.workspaces = rows
        return store
    }

    /// The input the Workspaces list gives the memo for `store` now.
    static func input(_ store: AppStore, _ memo: WorkspaceInbox.Memo, scope: MacScope = .all, query: String = "",
                      macs: [MacDevice] = macs) -> WorkspaceInbox.Memo.Input {
        let changed = memo.revision.flatMap { since in store.rowsChanged(since: since).map { (since, $0) } }
        return WorkspaceInbox.Memo.Input(scope: scope, macs: macs, workspaces: store.workspaces,
                                         workspacesRevision: store.workspacesRevision, query: query, changedRows: changed)
    }

    /// One changed row in a 500-row list: the inbox reads that row, builds nothing whole, and is
    /// the inbox a whole build makes.
    @Test func oneChangedRowReadsOneRowOf500() {
        let store = Self.store(Self.rows(500))
        let memo = WorkspaceInbox.Memo()
        _ = memo.inbox(Self.input(store, memo))
        let whole = memo.wholeBuilds, read = memo.rowsEvaluated
        var row = store.workspaces[250]
        row.title = "agent 250 (spinner)"
        store.updateWorkspaces(macID: row.macID, rows: [row])
        let inbox = memo.inbox(Self.input(store, memo))
        #expect(memo.wholeBuilds == whole, "a changed title built the whole inbox")
        #expect(memo.rowsEvaluated - read == 1, "rows read for one changed row: \(memo.rowsEvaluated - read)")
        #expect(memo.lastPatchedRows == ["w250"], "the row kept its place: the list redraws it alone")
        #expect(inbox == WorkspaceInbox(scope: .all, macs: Self.macs, workspaces: store.workspaces))
    }

    /// An active workspace jumps to the top (newer activity): an update with one move, reading
    /// one row, not a whole build.
    @Test func aRowJumpingToTheTopIsAnUpdateWithOneMove() {
        let store = Self.store(Self.rows(500))
        let memo = WorkspaceInbox.Memo()
        _ = memo.inbox(Self.input(store, memo))
        let whole = memo.wholeBuilds, read = memo.rowsEvaluated
        var row = store.workspaces[400]
        row.lastActivityAt = Self.now.addingTimeInterval(60)
        row.isWorking.toggle()
        store.updateWorkspaces(macID: row.macID, rows: [row])
        let inbox = memo.inbox(Self.input(store, memo))
        #expect(memo.wholeBuilds == whole)
        #expect(memo.rowsEvaluated - read == 1)
        #expect(memo.lastPatch?.moved == true)
        #expect(inbox.recent.first?.id == "w400")
        #expect(inbox == WorkspaceInbox(scope: .all, macs: Self.macs, workspaces: store.workspaces))
    }

    /// The same through the store's whole-list setter (a Mac's whole list, rows changed in place).
    @Test func aWholeListWithRowsChangedInPlaceReadsThoseRows() {
        let store = Self.store(Self.rows(500))
        let memo = WorkspaceInbox.Memo()
        _ = memo.inbox(Self.input(store, memo))
        let read = memo.rowsEvaluated
        var next = store.workspaces
        next[3].isWorking.toggle()
        next[410].needsAttention = true
        store.workspaces = next
        let inbox = memo.inbox(Self.input(store, memo))
        #expect(memo.rowsEvaluated - read == 2)
        #expect(inbox.needsYou.map(\.id) == ["w410"])
        #expect(inbox == WorkspaceInbox(scope: .all, macs: Self.macs, workspaces: store.workspaces))
    }

    /// Rows coming or going, an offline Mac's row, a new search or a reorder in the Mac's own
    /// order still build the inbox whole.
    @Test func otherChangesBuildWhole() {
        let store = Self.store(Self.rows(40, macs: ["m1", "m2", "m3"]))
        let memo = WorkspaceInbox.Memo()
        _ = memo.inbox(Self.input(store, memo))
        var whole = memo.wholeBuilds
        store.workspaces.removeLast()
        _ = memo.inbox(Self.input(store, memo))
        #expect(memo.wholeBuilds == whole + 1, "a removed row")
        whole = memo.wholeBuilds
        var offline = store.workspaces[2]
        #expect(offline.macID == "m3")
        offline.title = "asleep"
        store.updateWorkspaces(macID: "m3", rows: [offline])
        let inbox = memo.inbox(Self.input(store, memo))
        #expect(memo.wholeBuilds == whole + 1, "an offline Mac's row (its fold)")
        #expect(inbox == WorkspaceInbox(scope: .all, macs: Self.macs, workspaces: store.workspaces))
        whole = memo.wholeBuilds
        _ = memo.inbox(Self.input(store, memo, query: "agent 1"))
        #expect(memo.wholeBuilds == whole + 1, "a new search")
    }

    /// A small deterministic generator (the same rounds on every run).
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var scope: MacScope
        var query: String
        var macOrder: Bool
        var testDescription: String { name }
    }

    static let cases = [
        Case(name: "all, newest first", scope: .all, query: "", macOrder: false),
        Case(name: "search", scope: .all, query: "agent 1", macOrder: false),
        Case(name: "one Mac", scope: .mac("m1"), query: "", macOrder: false),
        Case(name: "Mac order", scope: .all, query: "", macOrder: true),
    ]

    /// 400 random live changes (activity that moves a row, an agent asking or answering, a
    /// working flag, a title, a pin, through either store path): after each one the updated inbox
    /// is exactly the inbox a whole build makes.
    @Test(arguments: cases) func everyUpdateIsTheWholeBuild(_ c: Case) {
        let store = Self.store(Self.rows(90, macOrder: c.macOrder, macs: ["m1", "m2", "m3"]))
        let memo = WorkspaceInbox.Memo()
        _ = memo.inbox(Self.input(store, memo, scope: c.scope, query: c.query))
        var random = Generator(state: 7)
        for round in 0..<400 {
            let count = 1 + random.next(3)
            var changed: [Workspace] = []
            for _ in 0..<count {
                var row = store.workspaces[random.next(store.workspaces.count)]
                guard !changed.contains(where: { $0.id == row.id }) else { continue }
                switch random.next(6) {
                case 0: row.lastActivityAt = Self.now.addingTimeInterval(Double(round))
                case 1: row.needsAttention.toggle()
                case 2: row.isWorking.toggle()
                case 3: row.title = "agent \(random.next(200)) r\(round)"
                case 4:
                    row.isPinned.toggle()
                    row.pinIndex = row.isPinned ? random.next(4) : nil
                default: row.focusOrder = random.next(5)
                }
                changed.append(row)
            }
            if random.next(2) == 0 {
                for macID in Set(changed.map(\.macID)) {
                    store.updateWorkspaces(macID: macID, rows: changed.filter { $0.macID == macID })
                }
            } else {
                var next = store.workspaces
                for row in changed { if let i = next.firstIndex(where: { $0.id == row.id }) { next[i] = row } }
                store.workspaces = next
            }
            let inbox = memo.inbox(Self.input(store, memo, scope: c.scope, query: c.query))
            let whole = WorkspaceInbox(scope: c.scope, macs: Self.macs, workspaces: store.workspaces, query: c.query)
            #expect(inbox == whole, "round \(round): the updated inbox differs from a whole build")
            if inbox != whole { return }
        }
        #expect(memo.patches > 0, "no update was patched (\(memo.wholeBuilds) whole builds)")
    }

    /// Two changes before the list reads the inbox (two publications in one pass): both rows.
    @Test func changesSinceTheLastInboxAreAllUpdated() {
        let store = Self.store(Self.rows(200))
        let memo = WorkspaceInbox.Memo()
        _ = memo.inbox(Self.input(store, memo))
        var a = store.workspaces[10], b = store.workspaces[11]
        a.title = "a"
        b.title = "b"
        store.updateWorkspaces(macID: a.macID, rows: [a])
        store.updateWorkspaces(macID: b.macID, rows: [b])
        let whole = memo.wholeBuilds
        let inbox = memo.inbox(Self.input(store, memo))
        #expect(memo.wholeBuilds == whole)
        #expect(inbox.workspace("w10")?.title == "a")
        #expect(inbox.workspace("w11")?.title == "b")
        #expect(inbox == WorkspaceInbox(scope: .all, macs: Self.macs, workspaces: store.workspaces))
    }
}
