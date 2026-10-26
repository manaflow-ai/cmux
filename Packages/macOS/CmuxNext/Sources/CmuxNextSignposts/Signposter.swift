public import CmuxNextTrace
public import os

/// Always-on signpost intervals for one ``SignpostCategory``, the same in Debug and Release.
///
/// Signposts of a custom subsystem are enabled by default, so the log system takes every interval
/// whether or not a recorder (`log stream --signpost`, Instruments) is attached: about a microsecond
/// per begin or end, and the message text the caller builds. Prefer the typed messages
/// (``ActionSignpostMessage``), whose fields the log system formats only when something reads them,
/// over a `String` built per call. Place intervals per user event or per frame, never per pane per
/// frame. Nothing leaves the Mac.
///
/// Every begin, end, event and flow hop also writes one record to the Release trace ring while its
/// name's category flag is on (``TraceRuntime``; one relaxed load when off). An interval that can
/// outlive its turn or overlap another of its name writes an async slice (AB/AE) keyed by its
/// `OSSignpostID`, like Chrome's `TRACE_EVENT_NESTABLE_ASYNC_BEGIN0`/`END0`; one that always begins and
/// ends inside one synchronous call on one thread (`SignpostName.opensThreadSlice`) writes a thread
/// slice (B/E), like `TRACE_EVENT_BEGIN0`/`END0` (base/trace_event/common/trace_event_common.h). A
/// record holds numbers only, never the message text:
/// - Begin `arg0`: the name's numbers (the typed overloads: an action's index and entrypoint, a scroll
///   phase, a main task's class and owner ids), with an input age in the top 24 bits where the begin
///   has one (`inputAgeBits(milliseconds:)`). `arg1` is the async id of an AB record.
/// - End `arg0`: bits 0-7 how it ended (`EndCode`), bits 8-15 a scroll's target (`ScrollFrameTarget.traceCode`).
///
/// ```swift
/// let state = Signposter.action.begin(.actionPerform, "id=\(id)")
/// defer { Signposter.action.end(.actionPerform, state) }
/// ```
public nonisolated struct Signposter: Sendable {
    /// The category this signposter emits.
    public let category: SignpostCategory
    private let signposter: OSSignposter
    /// The MetricKit mirror this signposter repeats intervals to (the app's: ``SignpostMetricKitMirror/shared``).
    private let mirror: SignpostMetricKitMirror
    /// The trace runtime whose ring takes this signposter's records (the app's: ``TraceRuntime/shared``).
    private let trace: TraceRuntime
    /// The trace clock an interval's begin time is read from (``SignpostInterval/beginUptimeNanos``).
    private let clock: TraceClock

    /// A signposter for `category` under ``SignpostCategory/subsystem``, recording into the process's trace ring.
    public init(category: SignpostCategory) {
        self.init(category: category, mirror: .shared, trace: .shared)
    }

    /// A signposter for `category` whose ring records go to `trace` (code that holds an injected runtime).
    public init(category: SignpostCategory, trace: TraceRuntime) {
        self.init(category: category, mirror: .shared, trace: trace)
    }

    /// - Parameters:
    ///   - mirror: The MetricKit mirror (tests pass their own, so they never switch the
    ///     process-wide one that other suites running in parallel read).
    ///   - trace: The trace runtime (tests pass their own, so their category flags and records are theirs).
    ///   - clock: The trace clock (tests pass one that reads a counter, so begin times are known).
    init(category: SignpostCategory, mirror: SignpostMetricKitMirror, trace: TraceRuntime = .shared,
         clock: TraceClock = TraceClock()) {
        self.category = category
        self.mirror = mirror
        self.trace = trace
        self.clock = clock
        signposter = OSSignposter(subsystem: SignpostCategory.subsystem, category: category.rawValue)
    }

    // The per-category handles below are declarations: OSSignposter is an immutable handle (like
    // `Logger`); the log system owns all state, so these are not singletons.
    /// ``SignpostCategory/action``.
    public static let action = Signposter(category: .action)
    /// ``SignpostCategory/motion``.
    public static let motion = Signposter(category: .motion)
    /// ``SignpostCategory/key``.
    public static let key = Signposter(category: .key)
    /// ``SignpostCategory/switch``.
    public static let `switch` = Signposter(category: .switch)
    /// ``SignpostCategory/create``.
    public static let create = Signposter(category: .create)
    /// ``SignpostCategory/cef``.
    public static let cef = Signposter(category: .cef)
    /// ``SignpostCategory/launch``.
    public static let launch = Signposter(category: .launch)
    /// ``SignpostCategory/stall``.
    public static let stall = Signposter(category: .stall)

    /// Whether anything takes this category's signposts: the log system (true unless a logging profile
    /// turns the subsystem off; it does not mean a recorder is attached) or the trace ring (the category's
    /// flag is on). Skip work that only feeds signposts when it is false.
    public var isEnabled: Bool { signposter.isEnabled || trace.isEnabled(categoryBit: category.traceBit) }

    /// Begins an interval named `name` with a public message.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: Public text recorded with the begin (ids and kinds, never user content).
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: String = "") -> SignpostInterval {
        openInterval(name, arg0: 0) { signposter.beginInterval(name.staticName, id: $0, "\(message, privacy: .public)") }
    }

    /// Begins an interval named `name` with an action's fields, formatted by the log system only
    /// when something reads them (`id=<id> origin=<origin> input_age_ms=<age, 2 decimals>`). The ring
    /// record carries the input age; ``begin(_:_:actionIndex:entrypoint:)`` adds the action's numbers.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: The action's id, origin and input age.
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: ActionSignpostMessage) -> SignpostInterval {
        begin(name, message, actionIndex: 0, entrypoint: 0)
    }

    /// Begins an interval named `name` with an action's fields, and its numbers in the ring record:
    /// `arg0` holds `actionIndex` in bits 0-31, `entrypoint` in bits 32-39 and the input age in the top 24.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: The action's id, origin and input age.
    ///   - actionIndex: The action's interned index (`ActionRunKey.index`; 0 when none was interned).
    ///   - entrypoint: The position of the run's `ActionEntrypoint` case.
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: ActionSignpostMessage, actionIndex: UInt32,
                      entrypoint: UInt8) -> SignpostInterval {
        let arg0 = UInt64(actionIndex) | UInt64(entrypoint) << 32 | Self.inputAgeBits(milliseconds: message.inputAgeMilliseconds)
        return openInterval(name, arg0: arg0) {
            signposter.beginInterval(
                name.staticName, id: $0,
                "id=\(message.id, privacy: .public) origin=\(message.origin, privacy: .public) input_age_ms=\(message.inputAgeMilliseconds, format: .fixed(precision: 2), privacy: .public)"
            )
        }
    }

    /// Begins a ``SignpostName/scrollToFrame`` interval with a scroll event's fields, formatted by the log system
    /// only when something reads them (`phase=<phase> age_ms=<age, 2 decimals>`): it runs on every scroll event
    /// (about 120 a second on a trackpad, plus momentum), so no `String` is built per call. The ring record's
    /// `arg0` holds the phase's `traceCode` and the age in the top 24 bits.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - scrollPhase: Which part of a scroll the event is.
    ///   - ageMilliseconds: The event's age when its dispatch began, or -1 without a timestamp.
    /// - Returns: The state to pass to ``end(_:_:_:scrollTarget:)``.
    public func begin(_ name: SignpostName, scrollPhase: ScrollFramePhase, ageMilliseconds: Double) -> SignpostInterval {
        openInterval(name, arg0: scrollPhase.traceCode | Self.inputAgeBits(milliseconds: ageMilliseconds)) {
            signposter.beginInterval(
                name.staticName, id: $0,
                "phase=\(scrollPhase.rawValue, privacy: .public) age_ms=\(ageMilliseconds, format: .fixed(precision: 2), privacy: .public)"
            )
        }
    }

    /// Begins an interval named `name` for one scheduled main-thread task (``SignpostName/stallMainTask``),
    /// with its class and owner formatted by the log system only when something reads them
    /// (`class=<class> owner=<owner>`): the scheduler opens one per task, so no `String` is built per call.
    /// ``begin(_:taskClass:owner:classID:ownerID:)`` adds their ids to the ring record.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - taskClass: The task's priority class name (`visible`, `automation`, ...).
    ///   - owner: The batch owner or control method that scheduled the task.
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, taskClass: String, owner: String) -> SignpostInterval {
        begin(name, taskClass: taskClass, owner: owner, classID: 0, ownerID: 0)
    }

    /// ``begin(_:taskClass:owner:)`` with the class and owner ids in the ring record: `arg0` holds `ownerID` in
    /// bits 0-31 and `classID` in bits 32-39.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - taskClass: The task's priority class name (`visible`, `automation`, ...).
    ///   - owner: The batch owner or control method that scheduled the task.
    ///   - classID: The class's number (`MainWorkClass`'s index).
    ///   - ownerID: The owner's id interned on the task board (`MainTaskOwner.index`).
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, taskClass: String, owner: String, classID: UInt8,
                      ownerID: UInt32) -> SignpostInterval {
        openInterval(name, arg0: UInt64(ownerID) | UInt64(classID) << 32) {
            signposter.beginInterval(name.staticName, id: $0, "class=\(taskClass, privacy: .public) owner=\(owner, privacy: .public)")
        }
    }

    /// Ends an interval begun with ``begin(_:_:)`` under the same name.
    public func end(_ name: SignpostName, _ interval: SignpostInterval) {
        signposter.endInterval(name.staticName, interval.state)
        if let id = interval.metricKitID { mirror.end(name, id: id) }
        closeInterval(name, interval, arg0: EndCode.ended)
    }

    /// Ends an interval that ``CommitBoundary`` closed: a ``CommitBoundary/Outcome/missed`` end
    /// carries the message `commit=missed`, so readers drop it instead of counting idle time. The
    /// MetricKit mirror ends only a committed interval: a missed one's begin stays unmatched, so
    /// MetricKit leaves it out of the histogram.
    public func end(_ name: SignpostName, _ interval: SignpostInterval, _ outcome: CommitBoundary.Outcome) {
        switch outcome {
        case .committed:
            signposter.endInterval(name.staticName, interval.state)
            if let id = interval.metricKitID { mirror.end(name, id: id) }
        case .missed:
            signposter.endInterval(name.staticName, interval.state, "commit=missed")
        }
        closeInterval(name, interval, arg0: EndCode.of(outcome))
    }

    /// ``end(_:_:_:)`` for a ``SignpostName/scrollToFrame`` interval, with who took the event, formatted by the log
    /// system only when something reads it: `target=<target>` on a committed end, `commit=missed target=<target>` on a
    /// missed one.
    ///
    /// - Parameters:
    ///   - name: The name the interval began with.
    ///   - interval: The state ``begin(_:scrollPhase:ageMilliseconds:)`` returned.
    ///   - outcome: How the ``CommitBoundary`` fired.
    ///   - scrollTarget: Who took the scroll event.
    public func end(_ name: SignpostName, _ interval: SignpostInterval, _ outcome: CommitBoundary.Outcome,
                    scrollTarget: ScrollFrameTarget) {
        switch outcome {
        case .committed:
            signposter.endInterval(name.staticName, interval.state, "target=\(scrollTarget.rawValue, privacy: .public)")
            if let id = interval.metricKitID { mirror.end(name, id: id) }
        case .missed:
            signposter.endInterval(name.staticName, interval.state, "commit=missed target=\(scrollTarget.rawValue, privacy: .public)")
        }
        closeInterval(name, interval, arg0: EndCode.of(outcome) | scrollTarget.traceCode << 8)
    }

    /// Ends an interval whose synchronous work ran a nested run loop that waited for the person
    /// (an `NSMenu` pop-up, a modal panel): the end carries `loop=nested`, so readers keep it out
    /// of latency rows instead of counting the person's dwell time. Like a missed commit, it is not
    /// mirrored to MetricKit.
    public func endSpanningNestedLoop(_ name: SignpostName, _ interval: SignpostInterval) {
        signposter.endInterval(name.staticName, interval.state, "loop=nested")
        closeInterval(name, interval, arg0: EndCode.nestedLoop)
    }

    /// Runs `body` inside an interval named `name`.
    ///
    /// - Returns: What `body` returns.
    public func interval<T>(_ name: SignpostName, _ message: String = "", _ body: () throws -> T) rethrows -> T {
        let interval = begin(name, message)
        defer { end(name, interval) }
        return try body()
    }

    /// Runs `body` inside an interval named `name` with an action's fields.
    ///
    /// - Returns: What `body` returns.
    public func interval<T>(_ name: SignpostName, _ message: ActionSignpostMessage, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name, message)
        defer { end(name, interval) }
        return try body()
    }

    /// Records a point event named `name`.
    public func event(_ name: SignpostName, _ message: String = "") {
        event(name, message, arg0: 0)
    }

    /// Records a point event named `name` with its numbers in the ring record (the name's doc comment in
    /// ``SignpostName`` says what `arg0` and `arg1` hold).
    ///
    /// - Parameters:
    ///   - name: A catalog name.
    ///   - message: Public text for the log system (ids and kinds, never user content).
    ///   - arg0: The ring record's first number.
    ///   - arg1: The ring record's second number.
    public func event(_ name: SignpostName, _ message: String, arg0: UInt64, arg1: UInt64 = 0) {
        signposter.emitEvent(name.staticName, "\(message, privacy: .public)")
        trace.event(name, arg0: arg0, arg1: arg1)
    }

    /// Records one hop of a key press's flow (``SignpostName/keyFlow``), formatted by the log system
    /// only when something reads it (`hop=<hop> flow=<id> age_us=<age>`). The ring record is an instant
    /// with the age in `arg0` (two's complement, so -1 reads back) and the flow id in `arg1`; the hop's
    /// name stays in the log system until hops are static names (p09-observability task 007).
    ///
    /// - Parameters:
    ///   - hop: The hop's name (`app.key.dispatch`, `app.io_write`, ...).
    ///   - flow: The key press's flow id.
    ///   - ageMicroseconds: The key event's age at this hop, or -1.
    public func flowHop(_ hop: String, flow: UInt64, ageMicroseconds: Int64 = -1) {
        assert(SignpostName.keyFlow.category == category, "key.flow is not in category \(category)")
        signposter.emitEvent(SignpostName.keyFlow.staticName,
                             "hop=\(hop, privacy: .public) flow=\(flow, privacy: .public) age_us=\(ageMicroseconds, privacy: .public)")
        trace.event(.keyFlow, arg0: UInt64(bitPattern: ageMicroseconds), arg1: flow)
    }

    // MARK: trace ring

    /// How an interval ended: bits 0-7 of its end record's `arg0`.
    enum EndCode {
        /// Ended normally, or at a committed ``CommitBoundary``.
        static let ended: UInt64 = 0
        /// The ``CommitBoundary`` missed the turn's commit (`commit=missed`).
        static let missed: UInt64 = 1
        /// The work ran a nested run loop that waited for the person (`loop=nested`).
        static let nestedLoop: UInt64 = 2

        /// The code of a ``CommitBoundary`` end.
        static func of(_ outcome: CommitBoundary.Outcome) -> UInt64 {
            switch outcome {
            case .committed: ended
            case .missed: missed
            }
        }
    }

    /// The top 24 bits of a begin record's `arg0` for an input age: the age in whole microseconds, saturated
    /// at `0xFF_FFFE` (16.7 s), or all ones for a begin with no input event (a negative or NaN age).
    static func inputAgeBits(milliseconds: Double) -> UInt64 {
        let none: UInt64 = 0xFF_FFFF
        guard milliseconds >= 0 else { return none << 40 }
        let micros = milliseconds * 1_000
        return (micros < Double(none - 1) ? UInt64(micros) : none - 1) << 40
    }

    /// Begins the log system's interval with `beginInterval`, the MetricKit mirror's and, while the name's
    /// category is on, the ring's slice with `arg0`.
    private func openInterval(_ name: SignpostName, arg0: UInt64,
                              _ beginInterval: (OSSignpostID) -> OSSignpostIntervalState) -> SignpostInterval {
        assert(name.category == category, "\(name) is not in category \(category)")
        let id = signposter.makeSignpostID()
        let beginNanos = clock.nowNanos()
        let state = beginInterval(id)
        return SignpostInterval(state: state, metricKitID: mirror.begin(name), beginUptimeNanos: beginNanos,
                                ring: traceBegin(name, id: id, beginNanos: beginNanos, arg0: arg0))
    }

    /// Writes the begin record when `name`'s category is on; returns the slice the end must close.
    private func traceBegin(_ name: SignpostName, id: OSSignpostID, beginNanos: UInt64, arg0: UInt64) -> SignpostInterval.Ring? {
        guard trace.isEnabled(categoryBit: name.traceCategory.traceBit) else { return nil }
        if name.opensThreadSlice {
            trace.begin(name, arg0: arg0)
            return .thread
        }
        let asyncID = Self.asyncID(id, beginNanos: beginNanos)
        trace.asyncBegin(name, id: asyncID, arg0: arg0)
        return .async(id: asyncID)
    }

    /// Writes the end record of a begin that wrote one.
    private func closeInterval(_ name: SignpostName, _ interval: SignpostInterval, arg0: UInt64) {
        switch interval.ring {
        case nil: return
        case .thread: trace.end(name, arg0: arg0)
        case .async(let id): trace.asyncEnd(name, id: id, arg0: arg0)
        }
    }

    /// The async id of an interval: its `OSSignpostID`, or its begin time when the log system handed out no
    /// id (a logging profile turned the subsystem off, so `makeSignpostID` returns `.null` or `.invalid`).
    static func asyncID(_ id: OSSignpostID, beginNanos: UInt64) -> UInt64 {
        id.rawValue == OSSignpostID.null.rawValue || id.rawValue == OSSignpostID.invalid.rawValue ? beginNanos : id.rawValue
    }
}

extension SignpostName {
    /// Whether a ``Signposter`` interval of this name is a thread slice (B/E) in the trace ring: it always begins
    /// and ends inside one synchronous call on one thread, so it nests in that thread's slices. These are the
    /// emitters' synchronous spans and the names whose catalog entry says "Ring: B/E". Every other name is an
    /// async slice (AB/AE), which decodes right wherever its end lands, so a new name defaults to that.
    var opensThreadSlice: Bool {
        switch self {
        case .actionPerform, .stallMainTask, .motionFrame, .motionDragFrame, .keyOmnibarSuggest, .keyPaletteSearch,
             .switchAppActivation, .cefPump, .cefGeometry, .stallCreateSurface, .stallPaletteOpen, .stallIconPickerOpen,
             .taskRun, .ghosttyRender:
            true
        default:
            false
        }
    }
}

extension ScrollFramePhase {
    /// The phase's number in a ``SignpostName/scrollToFrame`` begin record (bits 0-7 of `arg0`). Fixed: rings
    /// written by an older build decode with the same numbers.
    var traceCode: UInt64 {
        switch self {
        case .touch: 1
        case .began: 2
        case .changed: 3
        case .ended: 4
        case .momentum: 5
        case .wheel: 6
        }
    }
}

extension ScrollFrameTarget {
    /// The target's number in a ``SignpostName/scrollToFrame`` end record (bits 8-15 of `arg0`). Fixed.
    var traceCode: UInt64 {
        switch self {
        case .layout: 1
        case .content: 2
        }
    }
}
