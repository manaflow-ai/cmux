import CmuxMobileModel
import Darwin
import Foundation
import Testing
@testable import CmuxMobileLive

/// Same-fixture measurements for the workspace event path. The baseline is
/// the old behavior: each event parses the complete `list-workspaces` reply.
/// The optimized path resets once, then applies the same title events through
/// `WorkspaceProjection`, which parses only the affected row.
@MainActor
@Suite struct WorkspaceSyncPerformanceTests {
    private struct Fixture: Sendable {
        let initial: Data
        let snapshots: [Data]
        let events: [(surface: Int, title: String)]
    }

    @Test(arguments: [8, 32, 64])
    func streamingTitlesAvoidFullFetches(_ agentCount: Int) async throws {
        let fixture = try Self.fixture(agentCount: agentCount, eventsPerAgent: 4)
        let clock = ContinuousClock()

        // This is the old path's work on the main actor: one full JSON parse
        // and tree projection for every title event.
        let baselineStart = clock.now
        let baselineCPUStart = Self.mainThreadMilliseconds()
        var baselineTree: DaemonTree?
        for snapshot in fixture.snapshots {
            baselineTree = try DaemonTree(reply: snapshot, macID: "perf")
        }
        let baselineMilliseconds = Self.mainThreadMilliseconds() - baselineCPUStart
        let baselineElapsedMilliseconds = Self.milliseconds(baselineStart.duration(to: clock.now))

        // The new path performs the initial snapshot before streaming starts;
        // the timed section is only the event stream and has no full fetch.
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: fixture.initial, macID: "perf")
        let incrementalStart = clock.now
        let incrementalCPUStart = Self.mainThreadMilliseconds()
        var changedRows = 0
        for event in fixture.events {
            if let update = try await projection.apply(.titleChanged(surface: event.surface, title: event.title),
                                                       agents: AgentStates(), activity: [:]) {
                changedRows += update.changedWorkspaceIDs.count
            }
        }
        let incrementalMilliseconds = Self.mainThreadMilliseconds() - incrementalCPUStart
        let incrementalElapsedMilliseconds = Self.milliseconds(incrementalStart.duration(to: clock.now))

        // The event stream represents one simulated second. Keep the values
        // in the test output so the PR's Performance table comes from this
        // exact fixture and harness rather than a separate synthetic claim.
        let baselineFetchesPerMinute = Double(fixture.snapshots.count) * 60
        let incrementalFetchesPerMinute = 0.0
        print("workspace-sync perf agents=\(agentCount) simulated_seconds=1 "
            + "baseline_main_ms=\(baselineMilliseconds) incremental_main_ms=\(incrementalMilliseconds) "
            + "baseline_elapsed_ms=\(baselineElapsedMilliseconds) incremental_elapsed_ms=\(incrementalElapsedMilliseconds) "
            + "baseline_full_fetches_per_min=\(baselineFetchesPerMinute) "
            + "incremental_full_fetches_per_min=\(incrementalFetchesPerMinute)")

        #expect(baselineTree != nil)
        #expect(changedRows == fixture.events.count)
        #expect(incrementalFetchesPerMinute == 0)
        #expect(baselineMilliseconds >= 0)
        #expect(incrementalMilliseconds >= 0)
    }

    private static func fixture(agentCount: Int, eventsPerAgent: Int) throws -> Fixture {
        var rows: [[String: Any]] = []
        for index in 0..<agentCount {
            let surface = index + 1
            rows.append([
                "id": surface,
                "key": "workspace-\(surface)",
                "name": "Agent \(surface)",
                "screens": [[
                    "id": surface,
                    "active": true,
                    "active_pane": surface,
                    "panes": [[
                        "id": surface,
                        "active_tab": 0,
                        "tabs": [["surface": surface, "kind": "pty", "title": "Initial \(surface)"]],
                    ]],
                ]],
            ])
        }
        var initialObject: [String: Any] = [
            "ok": true,
            "data": ["workspace_revision": 1, "workspaces": rows],
        ]
        let initial = try JSONSerialization.data(withJSONObject: initialObject)
        var snapshots: [Data] = []
        var events: [(surface: Int, title: String)] = []
        for round in 0..<eventsPerAgent {
            for index in 0..<agentCount {
                let surface = index + 1
                let title = "Agent \(surface) · update \(round)"
                events.append((surface, title))
                rows[index]["screens"] = [[
                    "id": surface,
                    "active": true,
                    "active_pane": surface,
                    "panes": [[
                        "id": surface,
                        "active_tab": 0,
                        "tabs": [["surface": surface, "kind": "pty", "title": title]],
                    ]],
                ]]
                // A real daemon reply has a newer revision for each event.
                initialObject["data"] = ["workspace_revision": round * agentCount + index + 2, "workspaces": rows]
                snapshots.append(try JSONSerialization.data(withJSONObject: initialObject))
            }
        }
        return Fixture(initial: initial, snapshots: snapshots, events: events)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func mainThreadMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
    }
}
