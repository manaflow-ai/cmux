public import AppKit
import CmuxNextCompat
import CmuxNextWakeups
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
/// Every line also carries the settle and its look (goal instant-splits, the frame-timeline table):
///
///     {...,"settled_ts":81234.7012,"settled_ms":134.1,"surface":"terminal","blank_first_frame":false,"drift_px":0}
///
/// - `settled_ts`: the end of the last commit that moved the transition (a spring frame, a sidebar slide's resize, a
///   drag's move) before a quiet ``quietWindow`` with no move, or at ``maximumSettleWait``; the first frame's when
///   nothing moved after it. A drag settles only after its release. `settled_ms` is `settled_ts - input_ts`.
/// - `surface`: the content kind of the panes the transition resized or showed (`terminal`, `browser`, `agent`,
///   `page`, ..., the pane's `surface_status` kind), `mixed` for more than one kind; absent when the layout has no content provider.
/// - `blank_first_frame`: true when the first frame showed a pane without its content: a resized pane whose own
///   commit had not come by the held snap's bound (it shows its ground fill, `showsLateGround`), a new pane whose
///   content had not presented yet (a terminal with no surface or no drawn content, a Chromium page reporting itself not visible; a WebKit tab reports nothing and counts as shown), or the
///   snapshot right split (its new pane is a flat fill by design). Absent when the caller has no signal (a drag).
///   It is the cheapest honest signal: the layout's own state at the first frame, no pixel read.
/// - `drift_px`: at the settle, the largest distance in device pixels between any shown pane's frame edge and its
///   pixel-aligned rest rect (where the layout's target puts it): 0 is landed exactly.
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
        /// A split to the right opening (the split key or the menu): input is the key press or click, the first frame
        /// is the first commit that shows the split begin (the snapshot's slide with `splitSnapshotOpen` on, else the
        /// held snap that shows the live panes). Its lines carry `path`: `snapshot` or `live`.
        case rightSplitOpen = "right_split_open"
        /// Any other split opening (down, left, up, or a right split the snapshot path does not take): more panes.
        case splitOpen = "split_open"
        /// A pane closing: fewer panes.
        case paneClose = "pane_close"
        /// A pane expanding to the whole screen (zoom), and back (unzoom).
        case zoom
        case unzoom
        /// The sidebar opening or closing (its slide resizes the screen's panes).
        case sideOpen = "side_open"
        case sideClose = "side_close"
    }

    nonisolated public static let fileName = "frame-timing.jsonl"
    nonisolated public static let olderName = "frame-timing.1.jsonl"
    /// One half of the ring.
    nonisolated public static let maximumBytes = 512 * 1024
    /// An event older than this when the transition's code sees it is not this transition's input.
    nonisolated static let maximumEventAge: CFTimeInterval = 1
    /// A change later than this after its input is not that input's (a split the daemon refused, then another change):
    /// it times nothing.
    nonisolated static let maximumChangeWait: CFTimeInterval = 2
    /// A transition settled once no move committed for this long.
    nonisolated static let quietWindow: CFTimeInterval = 0.1
    /// A transition still moving this long after its input settles now (a drag held still is released by then).
    nonisolated static let maximumSettleWait: CFTimeInterval = 5

    private enum Phase {
        case idle
        /// Began; waits for its input (a divider drag's first move).
        case armed(Transition)
        /// Has its input; waits for the first change.
        case waiting(Transition, input: CFTimeInterval, fromEvent: Bool)
        /// Its first change is in the open transaction; waits for the commit.
        case marked(Transition, input: CFTimeInterval, fromEvent: Bool)
        /// Its first frame committed; each move re-marks the probe, its line is written once quiet (``settle()``).
        case settling(Transition, input: CFTimeInterval, fromEvent: Bool, first: (displayed: CFTimeInterval, ended: CFTimeInterval))
    }

    /// What the marked change says about its frames, written with its line.
    private struct Mark {
        var path: String?
        var endsAtDisplay = false
        var surface: String?
        var blank: Bool?
        var drift: (@MainActor () -> Double?)?
    }

    nonisolated let directory: URL
    nonisolated let url: URL
    nonisolated let olderURL: URL
    nonisolated let bound: Int
    nonisolated let build: String
    private var phase = Phase.idle
    /// The marked change's path (`snapshot`, `live`), surface, blank flag and drift reader. `endsAtDisplay`: the marked
    /// change was committed by an explicit flush in the input's own turn (the snapshot path): its frame was handed over
    /// at the commit's display step, and the run loop block after it waits on the rest of that turn.
    private var mark = Mark()
    /// The settling transition's last moved commit's end, whether a move waits for its commit, and whether it was released
    /// (a drag settles only after its release; every other kind is released at its input).
    private var settled: CFTimeInterval = 0
    private var moveMarked = false
    private var released = true
    private let quiet = DemandTimer(owner: "frame-timing.settle")
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
        if case .settling = phase { settle() }
        phase = .armed(transition)
        released = transition != .dividerDrag
        work = workCounts.map { (transition, $0(), nil, 0) }
    }

    /// The armed transition's input: the pointer event the app handles now, or `now` when it handles none of this
    /// transition's. Every later call until the next ``arm(_:)`` costs one comparison.
    public func input(now: CFTimeInterval = CACurrentMediaTime(), event: NSEvent? = NSApp?.currentEvent) {
        if work != nil { work?.moves += 1 }
        guard case let .armed(transition) = phase else { return }
        let pointer: Set<NSEvent.EventType> = [.leftMouseDragged, .leftMouseDown, .leftMouseUp, .mouseMoved, .keyDown]
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
        released = true
        if case .settling = phase { scheduleSettle() }
        guard let work, let input = work.input, let counts = workCounts?() else { self.work = nil; return }
        self.work = nil
        let before = Dictionary(work.counts, uniquingKeysWith: { first, _ in first })
        let line = Self.workLine(work.transition, input: input, ended: now, moves: work.moves,
                                 deltas: counts.map { ($0.0, $0.1 - (before[$0.0] ?? $0.1)) }, build: build,
                                 atMilliseconds: (Date().timeIntervalSince1970 * 1000).rounded())
        write(line)
    }

    /// The transition's first change is in the transaction open now, in `window`: its commit is the first frame.
    /// `path` goes on the line. `endsAtDisplay`: the caller flushes that transaction now, in the input's turn, so the
    /// commit's display step is when the frame went to the window server (``Mark``). `surface`, `blank`: the line's
    /// fields; `drift` is read at the settle. `kinds`: only these transitions take it (nil: any). A later change of a
    /// settling transition is one of its moves (``moved(in:)``).
    public func changed(in window: NSWindow?, path: String? = nil, endsAtDisplay: Bool = false, surface: String? = nil,
                        blank: Bool? = nil, drift: (@MainActor () -> Double?)? = nil, for kinds: Set<Transition>? = nil,
                        now: CFTimeInterval = CACurrentMediaTime()) {
        if case let .settling(transition, _, _, _) = phase {
            if kinds?.contains(transition) ?? true { moved(in: window) }
            return
        }
        guard case let .waiting(transition, input, fromEvent) = phase, kinds?.contains(transition) ?? true else { return }
        guard let host = window?.contentView?.layer, now - input < Self.maximumChangeWait else {
            phase = .idle
            return
        }
        phase = .marked(transition, input: input, fromEvent: fromEvent)
        mark = Mark(path: path, endsAtDisplay: endsAtDisplay, surface: surface, blank: blank, drift: drift)
        probe.mark(in: host)
    }

    /// The settling transition moved in the transaction open now (a spring frame, a resize): its commit is the settle
    /// so far. One enum comparison when nothing settles.
    public func moved(in window: NSWindow?) {
        guard case .settling = phase, !moveMarked, let host = window?.contentView?.layer else { return }
        moveMarked = true
        probe.mark(in: host)
    }

    /// A transition is between its first frame and its settle (the layout reports its moves then).
    public var isSettling: Bool {
        if case .settling = phase { true } else { false }
    }

    /// The armed or waiting transition, if any (the layout asks whether a split is timed).
    public var pendingTransition: Transition? {
        switch phase {
        case .idle: nil
        case let .armed(transition), let .waiting(transition, _, _), let .marked(transition, _, _): transition
        case .settling: nil
        }
    }

    /// The transition ended with no change to time (a click, Escape): nothing is written. A transition past its first
    /// change keeps timing to its settle.
    public func cancel() {
        work = nil
        switch phase {
        case .marked, .settling: return
        case .idle, .armed, .waiting: phase = .idle
        }
    }

    /// A probed commit's times: the first frame, or a move of the settle.
    func committed(displayed: CFTimeInterval, ended: CFTimeInterval) {
        probe.remove()
        switch phase {
        case let .marked(transition, input, fromEvent):
            let first = (displayed: displayed, ended: mark.endsAtDisplay ? displayed : ended)
            phase = .settling(transition, input: input, fromEvent: fromEvent, first: first)
            (settled, moveMarked) = (first.ended, false)
            scheduleSettle()
        case .settling:
            (settled, moveMarked) = (ended, false)
        case .idle, .armed, .waiting:
            break
        }
    }

    private func scheduleSettle() {
        guard released, !quiet.isScheduled else { return }
        quiet.schedule(after: .milliseconds(Int(Self.quietWindow * 1000)), reason: "settle") { @MainActor [weak self] in
            self?.settleIfQuiet()
        }
    }

    /// Writes the settling transition's line once no move committed for ``quietWindow``, else waits again: one deadline
    /// a window, not one a frame.
    private func settleIfQuiet(now: CFTimeInterval = CACurrentMediaTime()) {
        guard case let .settling(_, input, _, _) = phase, released else { return }
        if now - settled >= Self.quietWindow || now - input >= Self.maximumSettleWait {
            settle()
        } else {
            scheduleSettle()
        }
    }

    /// Writes the settling transition's line now (tests; the next ``arm(_:)``).
    func settle() {
        guard case let .settling(transition, input, fromEvent, first) = phase else { return }
        phase = .idle
        quiet.cancel()
        let drift = mark.drift?()
        let line = Self.line(transition, input: input, displayed: first.displayed, ended: first.ended, fromEvent: fromEvent,
                             build: build, atMilliseconds: (Date().timeIntervalSince1970 * 1000).rounded(), path: mark.path,
                             settled: max(settled, first.ended), surface: mark.surface, blank: mark.blank, drift: drift)
        (mark, moveMarked, released) = (Mark(), false, true)
        probe.remove()
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
        case let .waiting(_, input, fromEvent), let .marked(_, input, fromEvent), let .settling(_, input, fromEvent, _):
            (input, fromEvent)
        }
    }

    /// Waits for every queued write (tests).
    nonisolated func flush() { writer.flush() }

    /// One line, newline included.
    nonisolated static func line(_ transition: Transition, input: CFTimeInterval, displayed: CFTimeInterval, ended: CFTimeInterval,
                                 fromEvent: Bool, build: String, atMilliseconds: Double, path: String? = nil,
                                 settled: CFTimeInterval? = nil, surface: String? = nil, blank: Bool? = nil,
                                 drift: Double? = nil) -> String {
        let buildJSON = jsonSafe(build)
        let settled = max(settled ?? ended, ended)
        func word(_ key: String, _ value: String?) -> String {
            value.map { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0 == "_" } ? ",\"\(key)\":\"\($0)\"" : "" } ?? ""
        }
        return "{\"transition\":\"\(transition.rawValue)\",\"ms\":\(ms(ended - input)),\"commit_ms\":\(ms(displayed - input)),"
            + "\"input_ts\":\(input),\"first_frame_ts\":\(ended),\"settled_ts\":\(settled),\"settled_ms\":\(ms(settled - input)),"
            + "\"event\":\(fromEvent),\"build\":\"\(buildJSON)\",\"at_ms\":\(Int64(atMilliseconds))"
            + word("path", path) + word("surface", surface)
            + (blank.map { ",\"blank_first_frame\":\($0)" } ?? "")
            + (drift.flatMap { $0.isFinite ? ",\"drift_px\":\((max(0, $0) * 100).rounded() / 100)" : nil } ?? "") + "}\n"
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
