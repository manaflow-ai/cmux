import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// cmuxterm-hq#13493 item 2 (Leo 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?",
/// "And other general perf"): the sidebar's row views are windowed, but a change that was not one row's insert or close
/// laid out every row and rebuilt every row cache. The daemon pushes a few session changes a second; at Leo's 10,789
/// sessions each was O(sessions). This bench runs the same changes at 100 and at 10,789 loose rows and prints, per
/// change, the main-thread time of the set and its render and the rows laid out (`layout_rows`), one
/// `SIDEBAR-STRUCTURAL-BENCH` line each. It uses only what the base has, so the same harness gives before and after.
/// It checks nothing: `SidebarStructuralSpliceTests` is the detector.
@MainActor @Suite(.serialized, .timeLimit(.minutes(10)), .closesItsWindows)
struct SidebarStructuralChangeBenchTests {
    typealias Insert = SidebarCreateInsertScalingTests

    static let sizes = [100, 10_789]
    static let rounds = 12

    /// One kind of change: what it does to the shown nodes in round `round` (each round undoes the one before).
    struct Change {
        var name: String
        var run: (Insert.Harness, inout [SidebarNode], Int) -> Void
    }

    /// A row's status block grows it (a script reporting its progress); the next round drops it. A progress label, which
    /// the default row shows (status entries and the log line are opt-in, so they leave the row's height as it is).
    static func statusRow(_ id: WorkspaceID, title: String, reported: Bool) -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: id, title: title)
        if reported {
            ws.reported = SidebarWorkspaceStatus(entries: [.init(key: "build", text: "Building")], progressLabel: "412 of 900 targets")
        }
        return ws
    }

    static let changes: [Change] = [
        // A row's content in place, its height kept (a title): the patch path, no layout before or after.
        Change(name: "update-same-height") { h, _, round in
            _ = h.model.patchWorkspaces([SidebarWorkspace(id: WorkspaceID("ci-5"), title: "workspace 5 \(round)")])
        },
        // A row's status block comes and goes: its height changes.
        Change(name: "update-height") { h, _, round in
            _ = h.model.patchWorkspaces([statusRow(WorkspaceID("ci-5"), title: "workspace 5", reported: round % 2 == 0)])
        },
        // One row moves to the top and back (a notification's move to the top).
        Change(name: "move-one") { h, nodes, round in
            let n = nodes.count
            if round % 2 == 0 { nodes.insert(nodes.remove(at: n - 2), at: 0) } else { nodes.insert(nodes.remove(at: 0), at: n - 2) }
            h.model.setSections(Insert.sections(nodes))
        },
        // Three sessions start at once, then end at once (a batch from the daemon).
        Change(name: "insert-three-then-close") { h, nodes, round in
            let at = [1, nodes.count / 2, nodes.count - 1]
            if round % 2 == 0 {
                for (i, k) in at.enumerated().reversed() {
                    nodes.insert(.workspace(SidebarWorkspace(id: WorkspaceID("ci-batch-\(i)"), title: "batch \(i)")), at: k)
                }
            } else {
                nodes.removeAll { if case let .workspace(ws) = $0 { ws.id.rawValue.hasPrefix("ci-batch-") } else { false } }
            }
            h.model.setSections(Insert.sections(nodes))
        },
    ]

    struct Sample {
        var change: String
        var count: Int
        var msP50: Double
        var msMax: Double
        var laidOutPerChange: Double
        var walkedPerChange: Double

        var line: String {
            String(format: "SIDEBAR-STRUCTURAL-BENCH change=%@ count=%d ms_per_change p50 %.3f max %.3f layout_rows_per_change=%.1f rows_walked_per_change=%.1f",
                   change, count, msP50, msMax, laidOutPerChange, walkedPerChange)
        }
    }

    static func measure(_ change: Change, count: Int) -> Sample {
        let h = Insert.make(count)
        defer { h.window.close() }
        var nodes = h.rows
        var times: [Double] = [], laidOut = 0, walked = 0
        let clock = ContinuousClock()
        // Round 0 warms the caches; it is dropped.
        for round in 0...(rounds * 2) {
            _ = SidebarPerfCounters.report(reset: true)
            let elapsed = clock.measure {
                change.run(h, &nodes, round)
                h.sidebar.renderNow()
            }
            let counts = SidebarPerfCounters.report(reset: true)
            guard round > 0 else { continue }
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
            laidOut += counts["layout_rows"] ?? 0
            walked += counts["rows_walked"] ?? 0
        }
        let sorted = times.sorted()
        let changes = Double(times.count)
        return Sample(change: change.name, count: count, msP50: sorted[sorted.count / 2], msMax: sorted.last ?? 0,
                      laidOutPerChange: Double(laidOut) / changes, walkedPerChange: Double(walked) / changes)
    }

    @Test func structuralChangesAtOneHundredAndTenThousandSevenHundredEightyNineRows() {
        for change in Self.changes {
            for count in Self.sizes { print(Self.measure(change, count: count).line) }
        }
    }
}
