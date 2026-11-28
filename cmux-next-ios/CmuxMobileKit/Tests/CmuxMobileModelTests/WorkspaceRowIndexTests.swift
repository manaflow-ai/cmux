import CmuxMobileModel
import Foundation
import Testing

/// RFD 0227 fix 4: `updateWorkspaces` finds a pushed row through a `[macID: [workspaceID: index]]`
/// index and moves the attention count by the row's own change. On random sequences of pushes
/// and topology writes the store equals the old linear lookup (`firstIndex` per row) and the
/// whole recount.
@MainActor
@Suite struct WorkspaceRowIndexTests {
    /// SplitMix64, so a failing seed replays.
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
        mutating func coin() -> Bool { below(2) == 0 }
    }

    static let macs = ["m1", "m2", "m3"]

    static func workspace(_ id: String, mac: String, attention: Bool = false, title: String = "ws") -> Workspace {
        Workspace(id: id, macID: mac, title: title, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 0),
                  needsAttention: attention)
    }

    static func store(_ workspaces: [Workspace]) -> AppStore {
        AppStore(teams: [Team(id: "t", name: "T", macs: [MacDevice(id: "m1", name: "A", isOnline: true),
                                                         MacDevice(id: "m2", name: "B", isOnline: true)])],
                 activeTeamID: "t", workspaces: workspaces, feed: [], tabMemory: .inMemory())
    }

    /// The old `updateWorkspaces`: a linear `firstIndex` per row on the whole list.
    static func linearUpdate(_ list: [Workspace], macID: String, rows: [Workspace], pending: Set<String>) -> [Workspace] {
        var next = list
        for row in rows {
            guard !pending.contains(row.id),
                  let index = next.firstIndex(where: { $0.macID == macID && $0.id == row.id }),
                  next[index] != row else { continue }
            next[index] = row
        }
        return next
    }

    static func recount(_ store: AppStore) -> Int {
        store.activeWorkspaces.count(where: \.needsAttention)
    }

    @Test func pushesEqualTheLinearLookupOnRandomSequences() {
        for seed in 0..<80 {
            var rng = Rng(state: UInt64(seed))
            var serial = 0
            var list: [Workspace] = (0..<(1 + rng.below(40))).map { _ in
                serial += 1
                // A few IDs repeat on one Mac, and across Macs: the first one is the one pushed.
                let id = rng.below(6) == 0 ? "w\(rng.below(max(serial, 1)))" : "w\(serial)"
                return Self.workspace(id, mac: Self.macs[rng.below(macs.count)], attention: rng.coin())
            }
            let store = Self.store(list)
            for step in 0..<150 {
                let context = "seed \(seed) step \(step)"
                switch rng.below(10) {
                case 0:
                    // A topology write: a Mac's whole list.
                    let mac = Self.macs[rng.below(Self.macs.count)]
                    let next = (0..<rng.below(12)).map { _ -> Workspace in
                        serial += 1
                        return Self.workspace("w\(rng.coin() ? serial : rng.below(serial))", mac: mac, attention: rng.coin())
                    }
                    store.replaceWorkspaces(macID: mac, with: next)
                    list = store.workspaces
                case 1:
                    if let id = list.randomID(&rng) { store.removeWorkspace(id); list = store.workspaces }
                case 2:
                    if let id = list.randomID(&rng) { store.renameWorkspace(id, to: "r\(step)"); list = store.workspaces }
                case 3:
                    serial += 1
                    let pending = Self.workspace("p\(serial)", mac: Self.macs[rng.below(Self.macs.count)], attention: rng.coin())
                    store.insertPending(pending)
                    list = store.workspaces
                case 4:
                    // The active team's Macs change (presence): the count follows.
                    let picked = Self.macs.filter { _ in rng.coin() }
                    store.setMacs(picked.map { MacDevice(id: $0, name: $0, isOnline: true) }, teamID: "t")
                default:
                    // A row push: some of one Mac's rows change (attention, title, working), some
                    // not; now and then one names another Mac, or an ID the Mac does not list.
                    let mac = Self.macs[rng.below(Self.macs.count)]
                    let mine = list.filter { $0.macID == mac }
                    var rows: [Workspace] = []
                    for _ in 0..<(1 + rng.below(4)) {
                        var row = mine.isEmpty || rng.below(8) == 0
                            ? Self.workspace("gone\(rng.below(5))", mac: mac) : mine[rng.below(mine.count)]
                        switch rng.below(5) {
                        case 0: row.needsAttention.toggle()
                        case 1: row.title = "t\(step)"
                        case 2: row.isWorking.toggle()
                        case 3: if rng.below(4) == 0 { row.macID = Self.macs[rng.below(Self.macs.count)] }
                        default: break
                        }
                        rows.append(row)
                    }
                    let pending = Set(list.map(\.id).filter(store.isPending))
                    let expected = Self.linearUpdate(list, macID: mac, rows: rows, pending: pending)
                    let revision = store.workspacesRevision
                    store.updateWorkspaces(macID: mac, rows: rows)
                    #expect(store.workspaces == expected, "\(context)")
                    #expect((store.workspacesRevision != revision) == (expected != list), "\(context)")
                    list = store.workspaces
                }
                #expect(store.attentionCount == Self.recount(store), "\(context)")
            }
        }
    }

    @Test func aPushFindsTheFirstRowOfARepeatedID() {
        let store = Self.store([Self.workspace("a", mac: "m1"), Self.workspace("a", mac: "m1", title: "second")])
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace("a", mac: "m1", attention: true, title: "pushed")])
        #expect(store.workspaces.map(\.title) == ["pushed", "second"])
        #expect(store.attentionCount == 1)
    }

    @Test func aPushAfterATopologyChangeUsesTheNewPlaces() {
        let store = Self.store([Self.workspace("a", mac: "m1"), Self.workspace("b", mac: "m1")])
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace("b", mac: "m1", attention: true)])
        store.replaceWorkspaces(macID: "m1", with: [Self.workspace("b", mac: "m1", attention: true), Self.workspace("c", mac: "m1")])
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace("c", mac: "m1", attention: true)])
        #expect(store.workspaces.map(\.id) == ["b", "c"])
        #expect(store.workspaces.map(\.needsAttention) == [true, true])
        #expect(store.attentionCount == 2)
    }

    @Test func aPushOnAMacOutsideTheTeamLeavesTheCount() {
        let store = Self.store([Self.workspace("a", mac: "m3")])
        store.updateWorkspaces(macID: "m3", rows: [Self.workspace("a", mac: "m3", attention: true)])
        #expect(store.workspaces[0].needsAttention)
        #expect(store.attentionCount == 0)
    }

    /// The measurement behind RFD 0227 hot path 3, at its scale (1,100 workspaces): the old
    /// per-push cost (linear lookup, whole-list compare, whole recount) against the index.
    /// Printed, not asserted on time: equality is the gate, the numbers go in the PR.
    @Test func costAtElevenHundredWorkspaces() {
        let list = (0..<1_100).map { Self.workspace("w\($0)", mac: $0 % 2 == 0 ? "m1" : "m2", attention: $0 % 7 == 0) }
        let indexed = Self.store(list)
        var oracle = list
        var rng = Rng(state: 11)
        let pushes: [(String, [Workspace])] = (0..<500).map { _ in
            let mac = rng.coin() ? "m1" : "m2"
            let mine = list.filter { $0.macID == mac }
            return (mac, (0..<(1 + rng.below(3))).map { _ in
                var row = mine[rng.below(mine.count)]
                row.needsAttention.toggle()
                row.title = "t\(rng.below(1_000))"
                return row
            })
        }
        let clock = ContinuousClock()
        var oracleCount = 0
        let oldTime = clock.measure {
            for (mac, rows) in pushes {
                let next = Self.linearUpdate(oracle, macID: mac, rows: rows, pending: [])
                if next != oracle { oracle = next }
                oracleCount = oracle.count(where: \.needsAttention)
            }
        }
        let newTime = clock.measure {
            for (mac, rows) in pushes { indexed.updateWorkspaces(macID: mac, rows: rows) }
        }
        print("appstore_row_push workspaces=1100 pushes=\(pushes.count) linear_per_push=\(oldTime / pushes.count) indexed_per_push=\(newTime / pushes.count)")
        #expect(indexed.workspaces == oracle)
        #expect(indexed.attentionCount == oracleCount)
    }
}

private extension [Workspace] {
    func randomID(_ rng: inout WorkspaceRowIndexTests.Rng) -> String? {
        isEmpty ? nil : self[rng.below(count)].id
    }
}
