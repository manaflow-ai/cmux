@testable import CmuxNextDaemon
import Foundation
import Testing

/// hq#19373 (Leo, ask c-ea62b204f6: "a graceful if not imperceptible state transition all around"): a
/// reconnect to the same daemon keeps the snapshot memo, so its first snapshot applies only what changed
/// instead of re-applying and re-indexing every record (~109 ms of main at 3,000 workspaces, cmux#54010).
@MainActor @Suite struct ReconnectSnapshotMemoTests {
    private static func workspace(_ index: Int, title: String = "t") -> WorkspaceSnapshot {
        let base = UInt64(index * 100)
        let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                tabs: (0..<3).map { TabSnapshot(surface: SurfaceID(rawValue: base + 10 + UInt64($0)), title: "\(title) \($0)") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
    }

    private static func session(_ count: Int, generation: DaemonGeneration? = "boot-a", changing changed: Int? = nil) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { workspace($0, title: $0 == changed ? "renamed" : "t") },
                   generation: generation, registryID: "reg")
    }

    private static func reconnect(_ store: DaemonStore, serial: UInt64, generation: String = "boot-a") {
        _ = store.apply(.disconnected(reason: "link dropped"))
        let envelope = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: 0),
                                           event: .connected(DaemonIdentity(generation: generation), generationChanged: false),
                                           sourceID: UUID())
        _ = store.apply(batch: [envelope])
    }

    @Test func aReconnectToTheSameDaemonAppliesOnlyWhatChangedWhileTheLinkWasDown() throws {
        let store = DaemonStore()
        Self.reconnect(store, serial: 1)
        store.apply(snapshot: Self.session(200))
        let models = store.workspaces
        Self.reconnect(store, serial: 2)
        let before = store.index.indexedRecords
        store.apply(snapshot: Self.session(200, changing: 7))
        let indexed = store.index.indexedRecords - before
        #expect(indexed <= 6, "a reconnect to the same daemon indexed \(indexed) records for one changed workspace")
        #expect(store.workspaces[7].screens.first?.panes.first?.tabs.first?.titleText == "renamed 0",
                "a change the daemon made while the link was down applies")
        #expect(zip(store.workspaces, models).allSatisfy { $0 === $1 }, "every workspace keeps its record")
        #expect(store.liveTreeEpoch == store.connectionEpoch)
    }

    @Test func anEventAppliedBeforeTheDropIsCorrectedByTheReconnectSnapshot() {
        let store = DaemonStore()
        Self.reconnect(store, serial: 1)
        store.apply(snapshot: Self.session(20))
        let surface = SurfaceID(rawValue: 3 * 100 + 10)
        _ = store.apply(.titleChanged(surface: surface, title: "from an event"))
        Self.reconnect(store, serial: 2)
        store.apply(snapshot: Self.session(20))
        #expect(store.index.tabsBySurface[surface]?.titleText == "t 0")
    }

    @Test func aReconnectToAnotherDaemonGenerationAppliesInFull() {
        let store = DaemonStore()
        Self.reconnect(store, serial: 1)
        store.apply(snapshot: Self.session(30))
        Self.reconnect(store, serial: 2, generation: "boot-b")
        let before = store.index.indexedRecords
        store.apply(snapshot: Self.session(30, generation: "boot-b"))
        #expect(store.index.indexedRecords - before == 30 * 6, "nothing another daemon's tree applied is trusted")
    }

    @Test func aTreeThatNamesNoGenerationAppliesInFullAfterAReconnect() {
        let store = DaemonStore()
        Self.reconnect(store, serial: 1)
        store.apply(snapshot: Self.session(30, generation: nil))
        Self.reconnect(store, serial: 2)
        let before = store.index.indexedRecords
        store.apply(snapshot: Self.session(30, generation: nil))
        #expect(store.index.indexedRecords - before == 30 * 6)
    }

    /// Before/after from cmux#54010's harness: the reconnect's first snapshot, now incremental, beside the
    /// full pass it replaces (a tree with no generation still takes it). Median of 7, printed, not gated.
    @Test(arguments: [500, 3000])
    func reconnectApplyCost(sessionSize: Int) {
        let clock = ContinuousClock()
        func median(_ durations: [Duration]) -> Double {
            let middle = durations.sorted()[durations.count / 2].components
            return Double(middle.seconds) * 1000 + Double(middle.attoseconds) / 1e15
        }
        func run(generation: DaemonGeneration?) -> Double {
            let store = DaemonStore()
            Self.reconnect(store, serial: 1)
            store.apply(snapshot: Self.session(sessionSize, generation: generation))
            var samples: [Duration] = []
            for round in 0..<7 {
                let tree = Self.session(sessionSize, generation: generation)
                Self.reconnect(store, serial: UInt64(round + 2))
                samples.append(clock.measure { store.apply(snapshot: tree) })
            }
            return median(samples)
        }
        let full = run(generation: nil), kept = run(generation: "boot-a")
        print(String(format: "reconnect-apply workspaces=%d tabs=%d full_ms=%.2f same_daemon_ms=%.2f",
                     sessionSize, sessionSize * 3, full, kept))
        #expect(kept.isFinite && full.isFinite)
    }
}
