@testable import CmuxMobileModel
import Foundation
import Testing

// The cache's writes are coalesced (`LiveSnapshotStore.minimumWriteInterval`): a burst of saves
// writes its first and its latest. Model check: on random sequences of saves (two accounts, two
// teams each, lists across the head/tail split, reads and flushes in between), what every read
// returns equals what the old store returns, the one that wrote every save
// (`minimumWriteInterval: nil`). Bench: `workspace_cache_save_burst` (CmuxMobileInstantPerfTests).

@Suite struct LiveSnapshotStoreCoalescingTests {
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    }

    private static func workspaces(mac: String, count: Int, edit: Int) -> [Workspace] {
        (0..<count).map { index in
            var ws = Workspace(id: "ws-\(index)", macID: mac, title: "workspace \(index) v\(index == edit % max(count, 1) ? edit : 0)",
                               directory: "~/src/\(index)",
                               tabs: [WorkspaceTab(id: "t-\(index)", kind: .terminal, title: "zsh")],
                               lastActivityAt: Date(timeIntervalSince1970: Double(1_000 + index)))
            ws.sidebarIndex = index
            return ws
        }
    }

    /// What a read returns, without the tail's name (a fresh UUID on every write).
    private static func normalized(_ snapshot: LiveSnapshot?) -> LiveSnapshot? {
        guard var snapshot else { return nil }
        for key in snapshot.workspaces.keys { snapshot.workspaces[key]?.tailToken = nil }
        return snapshot
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-coalesce-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test(arguments: 0..<40)
    func coalescedReadsEqualWritingEverySave(seed: Int) {
        var rng = Rng(state: UInt64(seed) &+ 0x9E37_79B9)
        let oldDirectory = Self.directory(), newDirectory = Self.directory()
        defer {
            try? FileManager.default.removeItem(at: oldDirectory)
            try? FileManager.default.removeItem(at: newDirectory)
        }
        let old = LiveSnapshotStore(directory: oldDirectory, minimumWriteInterval: nil)
        // A long interval: only reads, flushes and the first save of a burst write.
        let new = LiveSnapshotStore(directory: newDirectory, minimumWriteInterval: .seconds(60))
        let accounts = ["user-a", "user/b"], teams = ["team-1", "team-2"], macs = ["mac-1", "mac-2"]
        for step in 0..<rng.int(5...60) {
            let account = accounts[rng.int(0...1)]
            switch rng.int(0...9) {
            case 0:
                old.flush()
                new.flush()
                #expect(Self.normalized(old.load(accountID: account)) == Self.normalized(new.load(accountID: account)),
                        "seed \(seed) step \(step): load")
            case 1:
                let team = teams[rng.int(0...1)]
                old.flush()
                #expect(Self.normalized(old.loadFirstScreen(accountID: account, teamID: team))
                        == Self.normalized(new.loadFirstScreen(accountID: account, teamID: team)),
                        "seed \(seed) step \(step): first screen of \(team)")
            default:
                let team = teams[rng.int(0...1)]
                var lists: [String: LiveSnapshot.MacWorkspaces] = [:]
                for mac in macs where rng.int(0...3) > 0 {
                    // Across the head's 40 rows, so tails are written, replaced and dropped.
                    lists[mac] = .init(workspaces: Self.workspaces(mac: mac, count: rng.int(0...90), edit: step),
                                       savedAt: Date(timeIntervalSince1970: Double(step)))
                }
                let snapshot = LiveSnapshot(teamID: team, teamName: team.uppercased(),
                                            macs: macs.map { MacDevice(id: $0, name: $0, isOnline: true) },
                                            linkedMacID: macs[rng.int(0...1)], workspaces: lists)
                old.save(snapshot, accountID: account)
                new.save(snapshot, accountID: account)
            }
        }
        old.flush()
        new.flush()
        for account in accounts {
            #expect(Self.normalized(old.load(accountID: account)) == Self.normalized(new.load(accountID: account)),
                    "seed \(seed): final load of \(account)")
            for team in teams {
                #expect(Self.normalized(old.loadFirstScreen(accountID: account, teamID: team))
                        == Self.normalized(new.loadFirstScreen(accountID: account, teamID: team)),
                        "seed \(seed): final first screen of \(account) \(team)")
            }
        }
    }

    @Test func aBurstWritesItsFirstAndItsLatestSave() {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LiveSnapshotStore(directory: directory, minimumWriteInterval: .seconds(60))
        let mac = MacDevice(id: "m", name: "Studio", isOnline: true)
        var last: LiveSnapshot?
        for step in 0..<200 {
            let snapshot = LiveSnapshot(teamID: "t", teamName: "T", macs: [mac], linkedMacID: "m",
                                        workspaces: ["m": .init(workspaces: Self.workspaces(mac: "m", count: 60, edit: step),
                                                                savedAt: Date(timeIntervalSince1970: Double(step)))])
            store.save(snapshot, accountID: "u")
            last = snapshot
        }
        store.flush()
        #expect(store.writeCount <= 2, "200 saves wrote \(store.writeCount) times")
        #expect(Self.normalized(store.load(accountID: "u")) == Self.normalized(last))
    }

    @Test func aWaitingSaveIsWrittenAfterTheInterval() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LiveSnapshotStore(directory: directory, minimumWriteInterval: .milliseconds(50))
        let mac = MacDevice(id: "m", name: "Studio", isOnline: true)
        func save(_ step: Int) {
            store.save(LiveSnapshot(teamID: "t", teamName: "T", macs: [mac], linkedMacID: "m",
                                    workspaces: ["m": .init(workspaces: Self.workspaces(mac: "m", count: 3, edit: step),
                                                            savedAt: Date(timeIntervalSince1970: Double(step)))]),
                       accountID: "u")
        }
        // The first write, done: the saves after it wait for the interval. (Saves made before the
        // queue takes the first one are all one write, so a burst with no flush may write once.)
        save(0)
        store.flush()
        #expect(store.writeCount == 1)
        save(1)
        save(2)
        // No flush: the trailing write comes by itself.
        let deadline = ContinuousClock.now + .seconds(10)
        while store.writeCount < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.writeCount == 2)
    }
}
