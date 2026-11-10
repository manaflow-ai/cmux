@testable import CmuxNextDaemon
import Foundation
import Testing

// TEMPORARY diagnostic (not for merge): where the main-thread cost of a one-workspace snapshot grows with N.
@MainActor @Suite(.serialized) struct SnapshotApplyScaleDiagTests {
    private static func session(_ count: Int, title: String, at changed: Int) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { index in
            let base = UInt64(index * 100)
            let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                    tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 10), title: index == changed ? title : "t")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        })
    }

    private static func stats(_ label: String, _ samples: [UInt64]) -> String {
        let s = samples.sorted()
        let mean = Double(s.reduce(0, +)) / Double(s.count)
        func q(_ p: Double) -> UInt64 { s[min(s.count - 1, Int(Double(s.count) * p))] }
        return "DIAG \(label) n=\(s.count) min=\(s.first!) p25=\(q(0.25)) med=\(q(0.5)) p90=\(q(0.9)) max=\(s.last!) mean=\(Int(mean))"
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Per-apply samples for one store of `count` workspaces.
    static func samples(_ count: Int, applies: Int, suppressMirror: Bool) async -> (whole: [UInt64], inner: [UInt64], lift: [UInt64], walked: Int, listWalked: Int, fingerprintApplies: Int) {
        let store = DaemonStore()
        store.apply(snapshot: session(count, title: "t", at: -1))
        var whole: [UInt64] = [], inner: [UInt64] = [], lift: [UInt64] = []
        var fingerprints = 0
        let walked0 = store.snapshotWorkspacesWalkedOnMain, list0 = store.workspaceListWalkedOnMain
        for i in 0..<applies {
            if suppressMirror { store.mirrorFingerprint = nil; store.mirrorFingerprintTakenAt = ContinuousClock.now.advanced(by: .seconds(100_000)) }
            let next = session(count, title: "a\(i)", at: count / 2)
            let diff = await store.snapshotDiff(of: next)
            let takenBefore = store.mirrorFingerprintTakenAt
            var begin = now()
            store.apply(snapshot: next, diff: diff)
            whole.append(now() - begin)
            if store.mirrorFingerprintTakenAt != takenBefore { fingerprints += 1 }
            // The incremental body alone, outside the overlay lift.
            let next2 = session(count, title: "b\(i)", at: count / 2)
            let diff2 = await store.snapshotDiff(of: next2)
            begin = now()
            if let d = store.incrementalDiff(next2, diff: diff2) {
                store.applyTreeIncrementally(next2, touching: store.touchedWorkspaces(d), diff: d)
                store.advanceSnapshotMemo(next2, applying: d)
            }
            inner.append(now() - begin)
            if suppressMirror { store.mirrorFingerprint = nil; store.mirrorFingerprintTakenAt = ContinuousClock.now.advanced(by: .seconds(100_000)) }
            // An empty lift.
            begin = now()
            store.withOverlayLifted(snapshot: true) {}
            lift.append(now() - begin)
        }
        return (whole, inner, lift, store.snapshotWorkspacesWalkedOnMain - walked0, store.workspaceListWalkedOnMain - list0, fingerprints)
    }

    @Test func diagnose() async {
        _ = await Self.samples(100, applies: 10, suppressMirror: false)
        for suppress in [false, true] {
            for rep in 0..<2 {
                for count in [100, 1000, 3000] {
                    let r = await Self.samples(count, applies: 60, suppressMirror: suppress)
                    let tag = "N=\(count) mirror=\(suppress ? "off" : "on") rep=\(rep)"
                    print(Self.stats("\(tag) whole", r.whole))
                    print(Self.stats("\(tag) inner", r.inner))
                    print(Self.stats("\(tag) lift", r.lift))
                    print("DIAG \(tag) walked=\(r.walked) listWalked=\(r.listWalked) fingerprintApplies=\(r.fingerprintApplies)")
                }
            }
        }
    }
}
