@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". The main-thread part of a `tree-changed`
/// that changed one workspace (its diff computed off main, as a live resync does) costs the same at 3,000 workspaces
/// as at 100.
@MainActor @Suite(.serialized) struct SnapshotApplyScaleTests {
    private static func session(_ count: Int, title: String, at changed: Int) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { index in
            let base = UInt64(index * 100)
            let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                    tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 10), title: index == changed ? title : "t")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        })
    }

    /// What the Debug build's mirror check (DaemonStore+MirrorCheck.swift) does in the timed applies. When a second of
    /// wall time passed since its last fingerprint, an apply takes a fingerprint of the whole tree, and the next apply
    /// takes it again to compare. A Release build has none of it.
    enum MirrorCheck: String {
        /// As the build does it: by the wall clock.
        case byTheClock = "as-built"
        /// No fingerprint in a timed apply.
        case out = "mirror-out"
        /// A fingerprint to compare and a new one in each timed apply.
        case inEachApply = "mirror-forced"
    }

    /// The main-thread nanoseconds of the applies of one round, and the round's wall time.
    struct Cost {
        var mean = Double.infinity, median = 0.0, max = 0.0, wallMs = 0.0
        var text: String { "mean \(Int(mean)) median \(Int(median)) max \(Int(max)) round_ms \(Int(wallMs))" }
    }

    /// One-workspace snapshot applies over `count` workspaces, `pause` apart: the round with the lowest mean of three.
    static func measure(_ count: Int, applies: Int = 60, pause: Duration = .zero, mirror: MirrorCheck) async -> Cost {
        let store = DaemonStore()
        store.apply(snapshot: session(count, title: "t", at: -1))
        var best = Cost()
        for round in 0..<3 {
            var samples: [UInt64] = []
            let start = DispatchTime.now().uptimeNanoseconds
            for i in 0..<applies {
                if pause > .zero { try? await Task.sleep(for: pause) }
                let next = session(count, title: "r\(round)-\(i)", at: count / 2)
                let diff = await store.snapshotDiff(of: next)
                switch mirror {
                case .byTheClock: break
                case .out:
                    store.mirrorFingerprint = nil
                    store.mirrorFingerprintTakenAt = ContinuousClock.now
                case .inEachApply:
                    store.mirrorFingerprintTakenAt = nil
                }
                let begin = DispatchTime.now().uptimeNanoseconds
                store.apply(snapshot: next, diff: diff)
                samples.append(DispatchTime.now().uptimeNanoseconds - begin)
            }
            let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            samples.sort()
            let mean = Double(samples.reduce(0, +)) / Double(applies)
            if mean < best.mean {
                best = Cost(mean: mean, median: Double(samples[applies / 2]), max: Double(samples[applies - 1]), wallMs: wall)
            }
        }
        return best
    }

    /// Main-thread nanoseconds per one-workspace snapshot apply over `count` workspaces, best of three rounds.
    static func applyCost(_ count: Int, applies: Int = 60) async -> Double {
        await measure(count, applies: applies, mirror: .byTheClock).mean
    }

    @Test func aOneWorkspaceSnapshotCostsTheMainThreadTheSameAt3000WorkspacesAsAt100() async {
        _ = await Self.applyCost(100, applies: 10) // warm up
        let small = await Self.applyCost(100)
        let mid = await Self.applyCost(1000)
        let large = await Self.applyCost(3000)
        print("snapshot-apply-cost ns/apply N=100 \(Int(small)) N=1000 \(Int(mid)) N=3000 \(Int(large))")
        #expect(large < small * 4, "a one-workspace snapshot at 3,000 workspaces took \(Int(large)) ns on main, at 100 \(Int(small)) ns")
    }

    /// The measured cost is the apply's, so it does not grow when the applies come slower in wall time, as they do in
    /// a test process under load (the daemon tier: 9 of 20 base runs red by this suite on 2026-11-11).
    @Test func theCostIsTheSameWhenTheAppliesComeSlower() async {
        _ = await Self.applyCost(100, applies: 10) // warm up
        let pause = Duration.milliseconds(110)
        let small = await Self.measure(100, applies: 12, pause: pause, mirror: .byTheClock)
        let large = await Self.measure(3000, applies: 12, pause: pause, mirror: .byTheClock)
        print("snapshot-apply-cost slow as-built N=100 \(small.text) | N=3000 \(large.text)")
        #expect(large.mean < small.mean * 4,
                "with 110 ms between the applies, one at 3,000 workspaces took \(Int(large.mean)) ns on main, at 100 \(Int(small.mean)) ns")
    }

    /// Diagnostic for the red above, not for a merge: the cost with the Debug mirror check out of the timed applies
    /// and with it in each of them.
    @Test func theShareOfTheDebugMirrorCheck() async {
        _ = await Self.applyCost(100, applies: 10) // warm up
        for mirror in [MirrorCheck.byTheClock, .out, .inEachApply] {
            var line = "snapshot-apply-cost fast \(mirror.rawValue)"
            for count in [100, 1000, 3000] {
                let cost = await Self.measure(count, mirror: mirror)
                line += " | N=\(count) \(cost.text)"
            }
            print(line)
        }
        var line = "snapshot-apply-cost slow mirror-out"
        for count in [100, 3000] {
            let cost = await Self.measure(count, applies: 12, pause: .milliseconds(110), mirror: .out)
            line += " | N=\(count) \(cost.text)"
        }
        print(line)
    }
}
