import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// v2.2.7-opt dogfood gate (cp/fix-wrap-stale-view): a new terminal whose first line is wider than its grid kept
/// showing only that line's first row while the daemon's screen had the shell's later output; the pane was drawing,
/// not paused, and the main thread idle (capture /work/tmp/dfo-evidence/longprobe/227-r2). One candidate per case:
/// after a replay into a surface that already has content (the first wrapped row) the session swaps in a fresh
/// surface, and live output that follows must reach the NEW surface's lane, by the stream and by the lane the IO is
/// told to feed (``TerminalOutputLaneNamer``).
@Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalWrapStaleViewTests {
    static var surface: ghostty_surface_t { unsafeBitCast(UInt(0x2000), to: ghostty_surface_t.self) }

    /// What the lanes parsed, in order.
    nonisolated final class StepLog: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var entries: [String] { lines.withLock { $0 } }
    }

    /// The lanes the IO was told to feed, in order (nil: none).
    nonisolated final class LaneLog: Sendable {
        private let named = Mutex<[TerminalOutputLane?]>([])
        func append(_ lane: TerminalOutputLane?) { named.withLock { $0.append(lane) } }
        var last: TerminalOutputLane?? { named.withLock { $0.last } }
    }

    /// An IO that only records which lane it is told to feed live output to.
    nonisolated final class NamedLaneIO: TerminalIO {
        let events: AsyncStream<TerminalIOEvent>
        let log = LaneLog()
        init() { (events, _) = AsyncStream<TerminalIOEvent>.makeStream() }
        func write(_ data: Data) async {}
        func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
        func setOutputLane(_ lane: TerminalEchoLane?) { log.append(lane?.lane) }
    }

    /// A lane whose parses go to `log` under its own name.
    private static func lane(_ name: String, log: StepLog) -> TerminalOutputLane {
        TerminalOutputLane(surface: surface, label: "test.wrap.\(name)",
                           parse: { _, data in log.append("\(name): \(String(decoding: data, as: UTF8.self))") },
                           setGrid: { _, columns, rows, _ in log.append("\(name): grid \(columns)x\(rows)") },
                           restore: { _, _, _ in true }, restoreLocal: { _, _, _, _ in 0 })
    }

    @Test func outputAfterAReplayIntoASurfaceWithContentReachesTheFreshSurface() async throws {
        let log = StepLog()
        let first = Self.lane("first", log: log), fresh = Self.lane("fresh", log: log)
        defer { first.close(); fresh.close() }
        let io = NamedLaneIO()
        let namer = TerminalOutputLaneNamer(io: io)
        let input = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "test.wrap.input", qos: .utility)) { _, _ in .next })
        var router = TerminalEventRouter(
            lane: first, mailbox: TerminalEventMailbox {},
            input: TerminalInputSink(lane: input, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()),
            outputLane: namer,
            replace: { event in
                // The session's swap: a fresh surface, the replay queued on its lane.
                if case .replay(let vt) = event { fresh.processOutput(vt) }
                return fresh
            })
        // The first row of a line one column wider than the 110-column grid: the surface has content.
        let row = String(repeating: "x", count: 110)
        #expect(await router.route(.output(Data(row.utf8))))
        await first.drained()
        #expect(io.log.last.flatMap { $0 } === first, "the IO was not told to feed the surface that has content")

        // The daemon's replay at the claimed grid: the surface has content, so a fresh one takes it.
        #expect(await router.route(.replay(Data("replay".utf8))))
        await fresh.drained()
        let named = io.log.last.flatMap { $0 }
        #expect(named === fresh, "after the swap the IO still feeds \(named === first ? "the replaced surface" : "no lane")")

        // Live output that follows, by the stream: it reaches the fresh surface, not the replaced one.
        #expect(await router.route(.output(Data("after".utf8))))
        await fresh.drained()
        #expect(log.entries.last == "fresh: after", "live output after the swap went to \(log.entries.last ?? "nowhere")")
        #expect(!log.entries.contains("first: after"))
    }
}
