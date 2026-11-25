#if os(iOS)
import Darwin
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Bench, opt-in like the tick harness: CMUX_VIEWPORT_WINDOW_BENCH=1, or the
/// CMUX_TICK_HARNESS=1 that `scripts/ci/cmux-next-ios-sim.sh` sets for an
/// only= naming `*/TickHarnessCellsTests*` (its env is fixed), so on the fleet:
/// `--arg only=CmuxMobileTerminalTests/TerminalHistoryWindowBench,CmuxMobileLiveTests/TickHarnessCellsTests/none`.
///
/// What the phone's Ghostty mirror pays for each replay shape of a Mac
/// terminal with 100,000 history rows, through the real surface: the bytes,
/// the time from the reset until the replay is parsed (the first frame can
/// draw then), and the process's memory footprint (phys_footprint, Xcode's
/// gauge) after it, against before the surface was made. The shapes are the
/// ones cmux-tui sends (`server/history_window_socket_tests.rs` measures them
/// on the wire): the whole history (every `resized` before, and the last
/// fetches of a scroll back to line 1), the newest 10,000 rows (the most a
/// tail holds now), a 4,000-row window far up (one step of a scroll back now),
/// and the screen alone (the attach). Prints VIEWPORT-WINDOW-SIM lines.
@MainActor
@Suite(.serialized, .enabled(if: ["CMUX_VIEWPORT_WINDOW_BENCH", "CMUX_TICK_HARNESS"].contains { ProcessInfo.processInfo.environment[$0] == "1" },
                             "opt-in bench: CMUX_VIEWPORT_WINDOW_BENCH=1"))
struct TerminalHistoryWindowBench {
    static let historyRows = 100_000
    static let screenRows = 24

    static func line(_ row: Int) -> String {
        String(format: "\u{1B}[32m%06ld\u{1B}[0m compiling crate-%ld v0.%ld.%ld (/home/dev/src/project/crates/c%ld) in %ldms\r\n",
               row, row % 977, row % 13, row % 101, row % 31, row % 4099)
    }

    /// A replay of history rows `rows`, then the screen.
    static func replay(_ rows: Range<Int>) -> Data {
        var text = "\u{1B}c"
        text.reserveCapacity((rows.count + screenRows) * 100)
        for row in rows { text += line(row) }
        for row in (historyRows - screenRows)..<historyRows { text += line(row) }
        text += "$ "
        return Data(text.utf8)
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// One fresh mirror fed `data`: (ms to parsed, footprint growth in bytes).
    func measure(_ data: Data) async -> (ms: Double, grew: Int64) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let before = Self.footprint()
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 2400))
        window.addSubview(surface)
        #expect(surface.surface != nil, "a live Ghostty surface parses the replay")
        let started = CFAbsoluteTimeGetCurrent()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            surface.feed(data, completion: { done.resume() })
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let grew = Int64(Self.footprint()) - Int64(before)
        surface.removeFromSuperview()
        window.isHidden = true
        return (ms, grew)
    }

    @Test func replayShapesOfAHundredThousandRowHistory() async throws {
        let shapes: [(String, Data)] = [
            ("screen (attach)", Self.replay(0..<0)),
            ("4k window far up (a scroll step, after)", Self.replay(40_000..<44_000)),
            ("newest 10k rows (largest tail, after)", Self.replay((Self.historyRows - 10_000 - Self.screenRows)..<(Self.historyRows - Self.screenRows))),
            ("whole 100k history (each resize and the last fetches, before)", Self.replay(0..<(Self.historyRows - Self.screenRows))),
        ]
        var out: [String] = []
        for (name, data) in shapes {
            var runs: [(ms: Double, grew: Int64)] = []
            for _ in 0..<3 { runs.append(await measure(data)) }
            let ms = runs.map(\.ms).sorted()[1]
            // The first surface grows the heap; later ones reuse what it freed, so
            // the largest growth is the shape's cost.
            let grew = runs.map(\.grew).max() ?? 0
            let megabytes = (Double(grew) / 1_048_576 * 10).rounded() / 10
            out.append("VIEWPORT-WINDOW-SIM \(name): \(data.count) bytes, parsed in \(Int(ms.rounded())) ms (median of 3), footprint +\(megabytes) MB (largest of 3)")
        }
        for line in out { print(line) }
        #expect(out.count == shapes.count)
        // The fleet step keeps no test stdout; it prints failure messages. A
        // run that asks for the bench by name gets its lines that way (the
        // bench then reads as failed: its numbers are the result).
        for line in out { Issue.record(Comment(rawValue: line)) }
    }
}
#endif
