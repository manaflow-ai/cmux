public import AppKit
import CmuxNextCompat
import Foundation
import os

nonisolated private let frameTimingLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "frame-timing")

/// Always-on frame timing of a transition, with no UI (goal instant-splits): the split-scale number went blind for 42 h
/// because one fleet-controller bench was the only way to read it. Each timed transition writes one JSON line:
///
///     {"transition":"divider_drag","ms":11.84,"commit_ms":10.92,"input_ts":81234.5671,"first_frame_ts":81234.5789,
///      "event":true,"build":"...","at_ms":1795000000000}
///
/// - `input_ts`: the input event's `NSEvent.timestamp` (`CACurrentMediaTime` seconds, `CLOCK_UPTIME_RAW`): for a
///   divider drag, the first pointer move of the drag (the press itself changes nothing). `event` false: the app was
///   not handling a pointer event at the move (a forwarded or synthesized one), so `input_ts` is the time the drag
///   code saw it, a lower bound of the latency.
/// - `first_frame_ts`: the end of the first Core Animation commit that carries the transition's first change
///   (``CommitProbe``: after AppKit's layout and display, the frame handed to the window server, which shows it at the
///   next vsync). `ms` is `first_frame_ts - input_ts`; `commit_ms` is the same to the commit's display step.
///
/// A drag also writes, at its release, one work line (``ended()``): what moved in the app's counters between its press and
/// its release (``workCounts``, the browser's page detaches, attaches and resize fence joins), and its move count:
///
///     {"transition":"divider_drag_work","ms":412.5,"moves":31,"detaches":0,"attaches":0,"fence_joined":93,...}
///
/// with `ms` the drag's first move to its release. A fence's answer that comes after the release counts in no drag.
///
/// One transition is timed at a time: a new one drops one still waiting for its change. `scripts/cmux-next/frame_timing.py`
/// prints each transition's p50, p95 and count from the file.
///
/// Cost: a pointer move does one enum comparison (the first move of a drag also reads `NSApp.currentEvent`). Once per
/// drag: one display of a 1-point layer that draws nothing, one run loop block, one line of about 200 bytes, appended
/// by ``CoalescingFileWriter`` on its utility queue (never the main thread). The file is a two-file ring in the
/// folder the app gives (`~/Library/Logs/cmux-next/<tag or release>/frame-timing.jsonl`, `AppServices.frameTiming`),
/// which becomes `frame-timing.1.jsonl` past ``maximumBytes`` (about 2,500 drags a half). The layout gets it as
/// `LayoutRootView.frameTiming`; nil (package tests, tools) times nothing.
@MainActor
public final class TransitionFrameLog {
    public enum Transition: String, Sendable {
        case dividerDrag = "divider_drag"
    }

    nonisolated public static let fileName = "frame-timing.jsonl"
    nonisolated public static let olderName = "frame-timing.1.jsonl"
    /// One half of the ring.
    nonisolated public static let maximumBytes = 512 * 1024
    /// An event older than this when the transition's code sees it is not this transition's input.
    nonisolated static let maximumEventAge: CFTimeInterval = 1

    private enum Phase {
        case idle
        /// Began; waits for its input (a divider drag's first move).
        case armed(Transition)
        /// Has its input; waits for the first change.
        case waiting(Transition, input: CFTimeInterval, fromEvent: Bool)
        /// Its first change is in the open transaction; waits for the commit.
        case marked(Transition, input: CFTimeInterval, fromEvent: Bool)
    }

    nonisolated let directory: URL
    nonisolated let url: URL
    nonisolated let olderURL: URL
    nonisolated let bound: Int
    nonisolated let build: String
    private var phase = Phase.idle
    private nonisolated let writer: CoalescingFileWriter
    private lazy var probe = CommitProbe { [weak self] displayed, ended in self?.committed(displayed: displayed, ended: ended) }
    /// Gets each line (tests); nil writes the file.
    var onLine: ((String) -> Void)?
    /// The counters a drag's work line reports (name, running total), read at its press and its release; nil writes no
    /// work line. The app reads the browser's (`CEFEngine.dragWorkCounts`): a few integer reads, twice a drag.
    public var workCounts: (@MainActor () -> [(String, Int)])?
    /// The drag whose work line comes at its release: its counters at the press, its first move and its moves.
    private var work: (transition: Transition, counts: [(String, Int)], input: CFTimeInterval?, moves: Int)?

    /// `workCounts`: the counters each drag's work line reports (``workCounts``).
    public nonisolated init(directory: URL, build: String, bound: Int = TransitionFrameLog.maximumBytes,
                            workCounts: (@MainActor () -> [(String, Int)])? = nil) {
        self.workCounts = workCounts
        self.directory = directory
        self.build = build
        self.bound = bound
        url = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
        olderURL = directory.appending(path: Self.olderName, directoryHint: .notDirectory)
        writer = CoalescingFileWriter(window: 1,
                                      onError: { _, error in
                                          frameTimingLogger.error("frame timing log write failed: \(String(describing: error), privacy: .public)")
                                      })
    }

    /// `transition` began (a divider press): its input comes next (``input(at:)``).
    public func arm(_ transition: Transition) {
        phase = .armed(transition)
        work = workCounts.map { (transition, $0(), nil, 0) }
    }

    /// The armed transition's input: the pointer event the app handles now, or `now` when it handles none of this
    /// transition's. Every later call until the next ``arm(_:)`` costs one comparison.
    public func input(now: CFTimeInterval = CACurrentMediaTime(), event: NSEvent? = NSApp?.currentEvent) {
        if work != nil { work?.moves += 1 }
        guard case let .armed(transition) = phase else { return }
        let pointer: Set<NSEvent.EventType> = [.leftMouseDragged, .leftMouseDown, .leftMouseUp, .mouseMoved]
        if let event, pointer.contains(event.type), now - event.timestamp >= 0, now - event.timestamp < Self.maximumEventAge {
            phase = .waiting(transition, input: event.timestamp, fromEvent: true)
            work?.input = event.timestamp
        } else {
            phase = .waiting(transition, input: now, fromEvent: false)
            work?.input = now
        }
    }

    /// The armed transition was released (a divider drag's mouse up, after its last change): its work line is written.
    public func ended(now: CFTimeInterval = CACurrentMediaTime()) {
        guard let work, let input = work.input, let counts = workCounts?() else { self.work = nil; return }
        self.work = nil
        let before = Dictionary(work.counts, uniquingKeysWith: { first, _ in first })
        let line = Self.workLine(work.transition, input: input, ended: now, moves: work.moves,
                                 deltas: counts.map { ($0.0, $0.1 - (before[$0.0] ?? $0.1)) }, build: build,
                                 atMilliseconds: (Date().timeIntervalSince1970 * 1000).rounded())
        write(line)
    }

    /// The transition's first change is in the transaction open now, in `window`: its commit ends the timing.
    public func changed(in window: NSWindow?) {
        guard case let .waiting(transition, input, fromEvent) = phase else { return }
        guard let host = window?.contentView?.layer else {
            phase = .idle
            return
        }
        phase = .marked(transition, input: input, fromEvent: fromEvent)
        probe.mark(in: host)
    }

    /// The transition ended with no change to time (a click, Escape): nothing is written.
    public func cancel() {
        work = nil
        if case .marked = phase { return }
        phase = .idle
    }

    private func committed(displayed: CFTimeInterval, ended: CFTimeInterval) {
        probe.remove()
        guard case let .marked(transition, input, fromEvent) = phase else { return }
        phase = .idle
        let line = Self.line(transition, input: input, displayed: displayed, ended: ended, fromEvent: fromEvent, build: build,
                             atMilliseconds: (Date().timeIntervalSince1970 * 1000).rounded())
        write(line)
    }

    private func write(_ line: String) {
        if let onLine {
            onLine(line)
        } else {
            writer.append(Data(line.utf8), to: url, rotatingTo: olderURL, limit: UInt64(bound))
        }
    }

    /// The timed transition's input time and whether it was an event's, once it has one (tests).
    var pendingInput: (time: CFTimeInterval, fromEvent: Bool)? {
        switch phase {
        case .idle, .armed: nil
        case let .waiting(_, input, fromEvent), let .marked(_, input, fromEvent): (input, fromEvent)
        }
    }

    /// Waits for every queued write (tests).
    nonisolated func flush() { writer.flush() }

    /// One line, newline included.
    nonisolated static func line(_ transition: Transition, input: CFTimeInterval, displayed: CFTimeInterval, ended: CFTimeInterval,
                                 fromEvent: Bool, build: String, atMilliseconds: Double) -> String {
        let buildJSON = jsonSafe(build)
        return "{\"transition\":\"\(transition.rawValue)\",\"ms\":\(ms(ended - input)),\"commit_ms\":\(ms(displayed - input)),"
            + "\"input_ts\":\(input),\"first_frame_ts\":\(ended),\"event\":\(fromEvent),\"build\":\"\(buildJSON)\","
            + "\"at_ms\":\(Int64(atMilliseconds))}\n"
    }

    /// One work line, newline included: `ms` the first move to the release, then the moves and each counter's change.
    nonisolated static func workLine(_ transition: Transition, input: CFTimeInterval, ended: CFTimeInterval, moves: Int,
                                     deltas: [(String, Int)], build: String, atMilliseconds: Double) -> String {
        let fields = deltas.filter { jsonSafe($0.0) == $0.0 && !$0.0.isEmpty }.map { ",\"\($0.0)\":\($0.1)" }.joined()
        return "{\"transition\":\"\(transition.rawValue)_work\",\"ms\":\(ms(max(0, ended - input))),\"moves\":\(moves)\(fields),"
            + "\"build\":\"\(jsonSafe(build))\",\"at_ms\":\(Int64(atMilliseconds))}\n"
    }

    nonisolated static func ms(_ seconds: CFTimeInterval) -> Double { (seconds * 100_000).rounded() / 100 }

    /// `text` when it needs no JSON escape, else "".
    nonisolated static func jsonSafe(_ text: String) -> String {
        text.unicodeScalars.allSatisfy { $0.isASCII && $0 != "\"" && $0 != "\\" && $0.value >= 0x20 } ? text : ""
    }
}
