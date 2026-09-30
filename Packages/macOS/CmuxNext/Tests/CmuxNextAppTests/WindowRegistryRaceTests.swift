@testable import CmuxNextApp
import Testing

/// Races on window membership: two clients removing the last workspaces at
/// once, a local move crossing a daemon removal, and a storm of moves,
/// tear-offs, closes and daemon changes. After every step no window is
/// empty and every live workspace has exactly one window.
struct WindowRegistryRaceTests {
    /// Deterministic PRNG (SplitMix64) so a failing seed replays.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func check(_ registry: WindowRegistry, live: Set<String>, step: String) {
        #expect(registry.violations().isEmpty, "\(step): \(registry.violations())")
        for window in registry.windows {
            #expect(!window.workspaceIDs.isEmpty, "\(step): \(window.id) is empty")
        }
        let owned = registry.windows.flatMap(\.workspaceIDs)
        #expect(owned.count == Set(owned).count, "\(step): a workspace has two windows")
        #expect(Set(owned).isSuperset(of: live), "\(step): live workspace without a window")
    }

    @Test func twoClientsRemovingTheLastWorkspacesAtOnceCloseBothWindows() {
        var registry = WindowRegistry()
        registry.openWindow(id: "a", workspaceIDs: ["w1"])
        registry.openWindow(id: "b", workspaceIDs: ["w2"])
        registry.openWindow(id: "c", workspaceIDs: ["w3"])
        // One daemon batch carries both closes.
        let changes = registry.reconcile(live: ["w3"], dead: ["w1", "w2"], fallbackWindow: "unused")
        #expect(Set(changes.emptied) == ["a", "b"])
        #expect(registry.windows.map(\.id) == ["c"])
        Self.check(registry, live: ["w3"], step: "both closed")
    }

    @Test func aLocalMoveCrossingADaemonRemovalLeavesNoEmptyWindow() {
        var registry = WindowRegistry()
        registry.openWindow(id: "a", workspaceIDs: ["w1", "w2"])
        registry.openWindow(id: "b", workspaceIDs: ["w3"])
        // This app moves w3 into a while another client closes it.
        registry.move(["w3"], to: "a")
        registry.reconcile(live: ["w1", "w2"], dead: ["w3"], fallbackWindow: "unused")
        #expect(registry.windows.map(\.id) == ["a"])
        Self.check(registry, live: ["w1", "w2"], step: "crossed")
        // And the other order: the removal first, then the stale move.
        registry.openWindow(id: "c", workspaceIDs: ["w2"])
        registry.reconcile(live: ["w1"], dead: ["w2"], fallbackWindow: "unused")
        registry.move(["w2"], to: "a")
        Self.check(registry, live: ["w1"], step: "stale move")
    }

    @Test func aStormOfMovesClosesAndDaemonChangesNeverLeavesAnEmptyWindow() {
        for seed in UInt64(1)...40 {
            var rng = Seeded(state: seed)
            var registry = WindowRegistry()
            var live = (1...8).map { "w\($0)" }
            var nextWorkspace = 9
            var nextWindow = 0
            func newWindowID() -> String {
                nextWindow += 1
                return "win\(nextWindow)"
            }
            registry.reconcile(live: live, dead: [], fallbackWindow: newWindowID())
            Self.check(registry, live: Set(live), step: "seed \(seed) start")
            for step in 0..<200 {
                let windows = registry.windows.map(\.id)
                let label = "seed \(seed) step \(step)"
                switch Int.random(in: 0..<6, using: &rng) {
                case 0 where !windows.isEmpty && !live.isEmpty:
                    // CLI / palette: move some workspaces to another window.
                    let ids = Array(live.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)))
                    registry.move(ids, to: windows.randomElement(using: &rng)!)
                case 1 where !live.isEmpty:
                    // Tear-off: a new window with some workspaces.
                    let ids = Array(live.shuffled(using: &rng).prefix(Int.random(in: 1...2, using: &rng)))
                    registry.openWindow(id: newWindowID(), workspaceIDs: ids)
                case 2 where !windows.isEmpty:
                    registry.close(windows.randomElement(using: &rng)!)
                case 3 where !live.isEmpty:
                    // Another client closes one or two workspaces.
                    let dead = Set(live.shuffled(using: &rng).prefix(Int.random(in: 1...2, using: &rng)))
                    live.removeAll { dead.contains($0) }
                    registry.reconcile(live: live, dead: dead, fallbackWindow: newWindowID())
                case 4:
                    // Another client creates a workspace.
                    live.append("w\(nextWorkspace)")
                    nextWorkspace += 1
                    registry.reconcile(live: live, dead: [], fallbackWindow: newWindowID())
                default:
                    registry.reconcile(live: live.shuffled(using: &rng), dead: [], fallbackWindow: newWindowID())
                }
                Self.check(registry, live: Set(live), step: label)
                if registry.violations().isEmpty == false { return }
            }
        }
    }
}
