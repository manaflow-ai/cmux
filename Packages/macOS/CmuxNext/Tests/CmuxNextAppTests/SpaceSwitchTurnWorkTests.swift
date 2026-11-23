import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// "changing spaces in sidebar also feels kinda slow" (Lawrence 2026-11-10). A space switch shows the space in
/// the turn of its input (`SpaceSwitchSameTurnTests`), but the work of one switch did not end there: the rows
/// pass that the switch ran in its own turn ran a second time on the observation hop of the same change, a walk
/// of every row of the space and a fill of the feed for a list that was already drawn. That hop runs before the
/// run loop commits the switch's frame, so the frame waited for it. Each test counts the work of one switch and
/// of every main-actor turn it starts, in a window the app's `WindowManager` holds. The size is the one
/// argument: 20, 400 and 826 workspaces (826 is the count of the session the budget is for), half in each space.
@MainActor @Suite(.serialized)
struct SpaceSwitchTurnWorkTests {
    @Test(arguments: [20, 400, 826])
    func aSwitchRunsTheRowsPassOnce(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, registered: true)
        defer { bench.close() }
        // Each space shown once: its rows are mapped and parked.
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        for round in 0..<6 {
            let counters = try await bench.settledSwitch(to: bench.rooms[(round + 1) % 2])
            let count = { (name: String) in counters[name] ?? 0 }
            print("SPACE-SWITCH-TURN-WORK n=\(total) switch=\(round) rows_passes=\(count("rebuilds")) list_reloads=\(count("list_reloads")) "
                + "layout_rows=\(count("layout_rows")) row_maps=\(count("row_maps")) section_sets=\(count("section_sets"))")
            #expect(count("rebuilds") == 1, "switch \(round) at \(total) workspaces: the rows pass ran \(count("rebuilds")) times for one switch")
            #expect(count("list_reloads") == 1, "switch \(round) at \(total) workspaces: \(count("list_reloads")) list layouts for one switch")
        }
    }
}
