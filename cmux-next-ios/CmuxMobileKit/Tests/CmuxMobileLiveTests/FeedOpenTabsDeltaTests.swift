import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// RFD 0227 fix 3: a row delta updates the Feed's open tabs per changed workspace, and the
/// result equals rebuilding them from the whole tree (`FeedOpenTabs(tree:)`) on random event
/// sequences.
@MainActor
@Suite struct FeedOpenTabsDeltaTests {
    static let mac = "mac-1"

    /// A small deterministic generator (SplitMix64), so a failing seed replays.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static func workspace(_ id: String, tabs: [String]) -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: "~",
                  tabs: tabs.map { WorkspaceTab(id: $0, kind: .terminal, title: $0) }, lastActivityAt: Date())
    }

    static func emptyTree() throws -> DaemonTree {
        try DaemonTree(reply: Data(#"{"ok":true,"data":{"workspaces":[]}}"#.utf8), macID: mac)
    }

    static func tree(workspaces: Int, tabs: Int) throws -> DaemonTree {
        var tree = try emptyTree()
        tree.workspaces = (0..<workspaces).map { w in workspace("w\(w)", tabs: (0..<tabs).map { "w\(w)-t\($0)" }) }
        tree.homeWorkspaces = [workspace("home", tabs: ["home-t0"])]
        return tree
    }

    /// One row event: some workspaces' tabs change (open, close, retitle with none), never the
    /// set of workspaces (that is a topology change, which takes the whole-tree path).
    static func rowEvent(_ tree: inout DaemonTree, rng: inout Rng, serial: inout Int) -> Set<String> {
        var ids: Set<String> = []
        for _ in 0..<(1 + rng.below(3)) {
            let home = rng.below(8) == 0
            let count = home ? tree.homeWorkspaces.count : tree.workspaces.count
            guard count > 0 else { continue }
            let index = rng.below(count)
            var row = home ? tree.homeWorkspaces[index] : tree.workspaces[index]
            switch rng.below(4) {
            case 0:
                serial += 1
                row.tabs.append(WorkspaceTab(id: "\(row.id)-n\(serial)", kind: .terminal, title: "n"))
            case 1:
                if !row.tabs.isEmpty { row.tabs.remove(at: rng.below(row.tabs.count)) }
            case 2:
                row.tabs.removeAll()
            default:
                break // a row event that changed no tab (a title, an agent status)
            }
            if home { tree.homeWorkspaces[index] = row } else { tree.workspaces[index] = row }
            ids.insert(row.id)
        }
        return ids
    }

    static func rows(_ tree: DaemonTree, rng: inout Rng) -> [FeedItem] {
        var items: [FeedItem] = []
        for workspace in tree.workspaces + tree.homeWorkspaces {
            for tab in workspace.tabs where rng.below(2) == 0 {
                var item = FeedItem(id: "r-\(tab.id)", kind: .response,
                                    workspaceID: workspace.id, tabID: tab.id, agentName: "Claude", harness: "claude",
                                    workspaceTitle: workspace.id, markdown: tab.id, quote: nil,
                                    createdAt: Date(timeIntervalSince1970: TimeInterval(items.count)))
                item.macID = mac
                items.append(item)
            }
        }
        return items
    }

    @Test func aDeltaEqualsTheWholeTreeOnRandomSequences() throws {
        for seed in 0..<60 {
            var rng = Rng(state: UInt64(seed))
            var tree = try Self.tree(workspaces: 1 + rng.below(30), tabs: rng.below(5))
            let items = Self.rows(tree, rng: &rng)
            let delta = FeedStore(items: items), whole = FeedStore(items: items)
            delta.setOpenTabs(FeedOpenTabs(tree: tree), macID: Self.mac)
            whole.setOpenTabs(FeedOpenTabs(tree: tree), macID: Self.mac)
            var model = FeedOpenTabs(tree: tree)
            var serial = 0
            for step in 0..<200 {
                let ids = Self.rowEvent(&tree, rng: &rng, serial: &serial)
                let changed = FeedOpenTabs.changedTabs(in: tree, workspaceIDs: ids)
                for (id, tabs) in changed { model.tabsByWorkspace[id] = tabs }
                #expect(model == FeedOpenTabs(tree: tree), "seed \(seed) step \(step)")
                delta.updateOpenTabs(changed, macID: Self.mac) { FeedOpenTabs(tree: tree) }
                whole.setOpenTabs(FeedOpenTabs(tree: tree), macID: Self.mac)
                #expect(delta.visibleItems.map(\.id) == whole.visibleItems.map(\.id), "seed \(seed) step \(step)")
                #expect(delta.needsYouIDs == whole.needsYouIDs, "seed \(seed) step \(step)")
            }
        }
    }

    @Test func aWorkspaceListedAsRowAndHomeUnionsBoth() throws {
        var tree = try Self.emptyTree()
        tree.workspaces = [Self.workspace("w1", tabs: ["t1"])]
        tree.homeWorkspaces = [Self.workspace("w1", tabs: ["h1"])]
        let changed = FeedOpenTabs.changedTabs(in: tree, workspaceIDs: ["w1", "gone"])
        #expect(changed["w1"] == .some(["t1", "h1"]))
        #expect(changed["gone"] == .some(nil))
        #expect(FeedOpenTabs(tree: tree).tabsByWorkspace["w1"] == ["t1", "h1"])
    }

    @Test func aDeltaBeforeAnyTreeTakesTheWholeList() throws {
        let tree = try Self.tree(workspaces: 3, tabs: 1)
        var item = FeedItem(id: "a", kind: .response, workspaceID: "w9", tabID: "x", agentName: "Claude", harness: "claude",
                            workspaceTitle: "w9", markdown: "a", quote: nil, createdAt: Date())
        item.macID = Self.mac
        let store = FeedStore(items: [item])
        // A launch snapshot's partial list: a workspace it does not list hides nothing.
        store.setOpenTabs(FeedOpenTabs(workspaces: [Self.workspace("w0", tabs: ["w0-t0"])], complete: false), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["a"])
        var built = 0
        store.updateOpenTabs(FeedOpenTabs.changedTabs(in: tree, workspaceIDs: ["w1"]), macID: Self.mac) {
            built += 1
            return FeedOpenTabs(tree: tree)
        }
        // The partial list is not patched: the tree's whole list replaces it, which knows w9 closed.
        #expect(built == 1)
        #expect(store.visibleItems.isEmpty)
    }

    @Test func anUnchangedDeltaDoesNotBuildTheWholeList() throws {
        let tree = try Self.tree(workspaces: 3, tabs: 2)
        let store = FeedStore(items: [])
        store.setOpenTabs(FeedOpenTabs(tree: tree), macID: Self.mac)
        var built = 0
        store.updateOpenTabs(FeedOpenTabs.changedTabs(in: tree, workspaceIDs: ["w1"]), macID: Self.mac) {
            built += 1
            return FeedOpenTabs(tree: tree)
        }
        #expect(built == 0)
    }

    /// The measurement behind RFD 0227 hot path 4, at its scale (1,100 workspaces): the old
    /// per-event cost (rebuild every tab, compare the whole dictionary) against the delta.
    /// Printed, not asserted on time: equality is the gate, the numbers go in the PR.
    @Test func costAtElevenHundredWorkspaces() throws {
        var tree = try Self.tree(workspaces: 1_100, tabs: 6)
        let items: [FeedItem] = []
        let old = FeedStore(items: items), new = FeedStore(items: items)
        old.setOpenTabs(FeedOpenTabs(tree: tree), macID: Self.mac)
        new.setOpenTabs(FeedOpenTabs(tree: tree), macID: Self.mac)
        let events = 500
        var rng = Rng(state: 7)
        var serial = 0
        var trees: [(DaemonTree, Set<String>)] = []
        for _ in 0..<events { trees.append((tree, Self.rowEvent(&tree, rng: &rng, serial: &serial))) }
        let clock = ContinuousClock()
        let oldTime = clock.measure {
            for (tree, _) in trees { old.setOpenTabs(FeedOpenTabs(tree: tree), macID: Self.mac) }
        }
        let newTime = clock.measure {
            for (tree, ids) in trees {
                new.updateOpenTabs(FeedOpenTabs.changedTabs(in: tree, workspaceIDs: ids), macID: Self.mac) { FeedOpenTabs(tree: tree) }
            }
        }
        let perOld = oldTime / events, perNew = newTime / events
        print("feed_open_tabs_row_event workspaces=1100 tabs=6600 events=\(events) whole_per_event=\(perOld) delta_per_event=\(perNew)")
        #expect(old.visibleItems == new.visibleItems)
    }
}
