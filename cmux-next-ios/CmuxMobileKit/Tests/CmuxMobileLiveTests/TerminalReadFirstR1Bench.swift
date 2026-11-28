// UIKit decode and the frame-rows scan are iOS only: the bench runs on the kit job's iOS
// simulator leg.
#if os(iOS)
import CmuxMobileTerminal
import CmuxMobileWorkspaces
import Darwin
import Foundation
import Testing
import UIKit

/// Leo, 2026-11-22 21:17Z (ask-bec34c9915): "like im sure theres a hell of s lot more value in
/// being able to read nigh instantly as much as possible / and the eventual consistency of writes
/// of whatever is a separate problem from being able to sync up my phone reading from mac but also
/// from what the phone itself is storing"
///
/// R1 (time to readable) for the terminal: the time from a tap to the first frame drawn from the
/// phone's own copy, with the link cut. The terminal already reads first:
/// `GhosttyTerminalTabContent` restores the tab's last frame (a JPEG in `TerminalFrameStore`) and
/// its last rows (`TerminalFrameStore.rows`) before it attaches. This times that path's steps, as
/// the restore runs them on the main thread:
///
/// - `frameStore.load(key)`, then `UIImage(data:)` and its decode for display (`preparingForDisplay`,
///   what the first draw of the still pays);
/// - `TerminalFrameRows.measure`, the scan `restoreLastFrame` runs on the still;
/// - `rowsStore.load(key)`, the UTF-8 decode, and `TerminalSeed.bytes`, the seed fed to the surface.
///
/// The SwiftUI draw of the still and Ghostty's parse of the seed are not in it.
///
/// - **Scales** 1x, 10x and 100x: the Mac's screen text is 40, 400 or 4,000 rows. The kept rows are
///   bounded (`TerminalSeed.maxRows`, `maxBytes`) and the frame is one phone screen, so R1 must stay
///   flat as the Mac's history grows.
/// - **cold**: a tab not read before in this process, on a fresh store, in a directory of 64 tabs whose
///   other 63 were written after it. The simulator does not drop the OS's file cache, so "cold" is
///   cold for the app's memory, not for the disk.
/// - **warm**: the same tab read again.
/// - **duress** (`CMUX_READ_FIRST_DURESS=1`, on by default): two writers rewrite the other 63 tabs'
///   frames and rows the whole time (the app writing stills as tabs cool), and the other cores spin.
///
/// It prints `NETCOND {json}` lines (surface `terminal`, profile `no-link@1`, metric `r1_ms`) in the
/// same form as the Rust leg (`cmux-mobile-core/tests/read_first_r1.rs`), so
/// `scripts/measure/ios-network-conditions-report.py` makes the R1 table from the step's log.
///
/// Opt-in: CMUX_READ_FIRST_R1=1, or the CMUX_TICK_HARNESS=1 the simulator step sets for an only=
/// naming `*/TickHarnessCellsTests*`:
/// `cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg test
///   --arg only=CmuxMobileLiveTests/TerminalReadFirstR1Bench,CmuxMobileLiveTests/TickHarnessCellsTests/none`.
@MainActor
@Suite(.serialized, .enabled(if: ["CMUX_READ_FIRST_R1", "CMUX_TICK_HARNESS"].contains { ProcessInfo.processInfo.environment[$0] == "1" },
                             "opt-in bench: CMUX_READ_FIRST_R1=1"))
struct TerminalReadFirstR1Bench {
    nonisolated static let tabs = 64
    nonisolated static let screenRows = 40
    /// A phone screen in pixels (6.1", 3x), as `TerminalFrameStore` keeps it.
    nonisolated static let frameSize = CGSize(width: 1179, height: 2556)

    nonisolated static var runs: Int {
        Int(ProcessInfo.processInfo.environment["NETCOND_RUNS"] ?? "") ?? 20
    }

    nonisolated static var duress: Bool {
        ProcessInfo.processInfo.environment["CMUX_READ_FIRST_DURESS"] != "0"
    }

    /// A terminal page as the app draws it: a build log on black, `jpegData(0.7)` as the app saves it.
    static func frame(_ tab: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: frameSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: frameSize))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 30, weight: .regular),
                                                             .foregroundColor: UIColor.green]
            for row in 0..<60 {
                NSString(string: String(format: "%06d tab %d compiling crate-%d v0.%d.%d in %dms", row, tab, row * 7, row % 13, row % 101, row * 31))
                    .draw(at: CGPoint(x: 8, y: CGFloat(row) * 36), withAttributes: attributes)
            }
        }
        return try #require(image.jpegData(compressionQuality: 0.7))
    }

    /// The rows the app keeps for a page whose screen text is `count` rows (`rowsForSaving`).
    nonisolated static func rows(_ tab: Int, count: Int) -> Data {
        let text = (0..<count).map { row in
            String(format: "\u{1B}[32m%06ld\u{1B}[0m tab %ld compiling crate-%ld v0.%ld.%ld (/home/dev/src/project/crates/c%ld) in %ldms",
                   row, tab, row % 977, row % 13, row % 101, row % 31, row % 4099)
        }.joined(separator: "\n")
        return Data((TerminalSeed.rows(fromScreenText: text) ?? "").utf8)
    }

    nonisolated static func key(_ tab: Int) -> TerminalFrameKey {
        TerminalFrameKey(accountID: "acct-r1", macID: "mac-r1", surfaceID: "surface-\(tab)")
    }

    /// The restore path's steps for one tab, in ms; nil when the tab gave nothing to draw.
    static func readFirst(_ store: TerminalFrameStore, _ key: TerminalFrameKey) -> Double? {
        let started = CFAbsoluteTimeGetCurrent()
        guard let data = store.load(key), let image = UIImage(data: data),
              let prepared = image.preparingForDisplay(), let cgImage = prepared.cgImage else { return nil }
        _ = TerminalFrameRows.measure(cgImage)
        guard let rowData = store.rows.load(key), let rows = String(data: rowData, encoding: .utf8),
              !TerminalSeed.bytes(rows: rows).isEmpty else { return nil }
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    /// Spinning threads and writers rewriting the other tabs, until `stop` is set.
    final class Load: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var stop: Bool {
            get { lock.withLock { stopped } }
            set { lock.withLock { stopped = newValue } }
        }

        func start(store: TerminalFrameStore, others: [Int], frames: [Data], rows: [Data]) {
            let spinners = max(ProcessInfo.processInfo.activeProcessorCount - 3, 1)
            for _ in 0..<spinners {
                Thread.detachNewThread { [self] in
                    var x: UInt64 = 1
                    while !stop { for _ in 0..<10_000 { x = x &* 6364136223846793005 &+ 1 } }
                    _ = x
                }
            }
            for writer in 0..<2 {
                Thread.detachNewThread { [self] in
                    var index = writer
                    while !stop {
                        let tab = others[index % others.count]
                        store.save(frames[index % frames.count], for: TerminalReadFirstR1Bench.key(tab))
                        store.rows.save(rows[index % rows.count], for: TerminalReadFirstR1Bench.key(tab))
                        index += 2
                    }
                }
            }
        }
    }

    @Test func terminalReadFirstR1() throws {
        let runs = Self.runs
        let frames = try (0..<4).map { try Self.frame($0) }
        var lines: [String] = []
        for (scale, count) in [("1x", Self.screenRows), ("10x", Self.screenRows * 10), ("100x", Self.screenRows * 100)] {
            let directory = FileManager.default.temporaryDirectory.appending(path: "terminal-r1-\(scale)-\(UUID().uuidString)")
            let writer = TerminalFrameStore(directory: directory)
            let rows = (0..<4).map { Self.rows($0, count: count) }
            // One tab per run is read cold; it is written first, the other tabs after it.
            let readTabs = Array(0..<runs)
            let others = Array(runs..<(runs + Self.tabs - 1))
            for tab in readTabs + others {
                writer.save(frames[tab % frames.count], for: Self.key(tab))
                writer.rows.save(rows[tab % rows.count], for: Self.key(tab))
            }
            let load = Load()
            if Self.duress { load.start(store: writer, others: others, frames: frames, rows: rows) }
            defer { load.stop = true }
            for run in 0..<runs {
                let store = TerminalFrameStore(directory: directory)
                let key = Self.key(readTabs[run])
                let cold = Self.readFirst(store, key)
                let warm = Self.readFirst(store, key)
                for (phase, ms) in [("cold", cold), ("warm", warm)] {
                    if ms == nil { lines.append("NETCOND-ERROR terminal \(phase) \(scale) run \(run): nothing drawn from the store") }
                    let value = ms.map { String(format: "%.3f", $0) } ?? "null"
                    lines.append(#"NETCOND {"surface":"terminal","profile":"no-link@1","phase":"\#(phase)","scale":"\#(scale)","metric":"r1_ms","value":\#(value),"run":\#(run),"seed":\#(run)}"#)
                }
                lines.append(#"NETCOND {"surface":"terminal","profile":"no-link@1","phase":"cold","scale":"\#(scale)","metric":"bytes_down","value":0,"run":\#(run),"seed":\#(run)}"#)
            }
            load.stop = true
            try? FileManager.default.removeItem(at: directory)
        }
        for line in lines { print(line) }
        #expect(!lines.contains { $0.hasPrefix("NETCOND-ERROR") })
        // The step shows failure messages, not stdout: record the lines so the result is readable there.
        for line in lines { Issue.record(Comment(rawValue: line)) }
    }
}
#endif
