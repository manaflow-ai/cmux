public import CmuxNextTrace
import class CmuxSafeConcurrency.Invariant
public import os

/// Always-on signpost intervals for one ``SignpostCategory``, the same in Debug and Release.
///
/// Signposts of a custom subsystem are enabled by default, so the log system takes every interval
/// whether or not a recorder (`log stream --signpost`, Instruments) is attached: about a microsecond
/// per begin or end, and the message text the caller builds. Prefer the typed messages
/// (``ActionSignpostMessage``), whose fields the log system formats only when something reads them,
/// over a `String` built per call. Place intervals per user event or per frame, never per pane per
/// frame. Nothing leaves the Mac. The emitters that run per key, per key hop and per scheduled main
/// task (`key.frame`, `key.flow`, `stall.main_task`, `stall.over_budget`; Signposter+NoAllocation.swift)
/// make no heap allocation.
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
///   has one (`inputAgeBits(milliseconds:)`). A code byte (entrypoint, class, phase) is its position + 1,
///   so 0 always means "not given" (`code(position:)`). `arg1` is the async id of an AB record.
/// - End `arg0`: bits 0-7 how it ended (`EndCode`), bits 8-15 a scroll's target (`ScrollFrameTarget.traceCode`).
/// - Flow hop (`key.flow`): a flow record (`s` for the press's first hop, `f` for the later ones) with the flow
///   id in `arg1` and, in `arg0`, the hop's `KeyFlowHop.traceCode` in bits 0-7 and its age in us (two's
///   complement, -1 without one) in bits 8-63.
///
/// A begin reads its category flag once: an end writes exactly when its begin wrote, even if the flag changed
/// in between, so the ring never holds a begin without its end or an end without its begin.
///
/// ```swift
/// let state = Signposter.action.begin(.actionPerform, "id=\(id)")
/// defer { Signposter.action.end(.actionPerform, state) }
/// ```
public nonisolated struct Signposter: Sendable {
    /// The category this signposter emits.
    public let category: SignpostCategory
    /// The log system's handle (the typed emitters in this module's extensions begin and end on it).
    let signposter: OSSignposter
    /// The MetricKit mirror this signposter repeats intervals to (the app's: ``SignpostMetricKitMirror/shared``).
    let mirror: SignpostMetricKitMirror
    /// The trace runtime whose ring takes this signposter's records (the app's: ``TraceRuntime/shared``).
    let trace: TraceRuntime
    /// The trace clock an interval's begin time is read from (``SignpostInterval/beginUptimeNanos``).
    let clock: TraceClock

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
    /// flag is on). Skip work that only feeds signposts when it is false. Always false for the key category
    /// while the keystroke-timing gate is closed (``TraceRuntime/isKeyTimingSuppressed``, task 128): the log
    /// system and the MetricKit mirror then take no key timing either, as the ring does not.
    public var isEnabled: Bool {
        if category == .key, trace.isKeyTimingSuppressed { return false }
        return signposter.isEnabled || trace.isEnabled(categoryBit: category.traceBit)
    }

    /// Begins an interval named `name` with a public message.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: Public text recorded with the begin (ids and kinds, never user content).
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: String = "") -> SignpostInterval {
        openInterval(name, arg0: 0) { signposter.beginInterval(name.staticName, id: $0, "\(message, privacy: .public)") }
    }

    /// Begins an interval named `name` with a public message and its numbers in the ring record's `arg0`
    /// (the name's doc comment in ``SignpostName`` says what `arg0` holds).
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: Public text recorded with the begin (ids and kinds, never user content).
    ///   - arg0: The begin record's first number.
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: String, arg0: UInt64) -> SignpostInterval {
        openInterval(name, arg0: arg0) { signposter.beginInterval(name.staticName, id: $0, "\(message, privacy: .public)") }
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
        beginAction(name, message, actionIndex: 0, entrypointCode: 0)
    }

    /// Begins an interval named `name` with an action's fields, and its numbers in the ring record:
    /// `arg0` holds `actionIndex` in bits 0-31, the entrypoint's code (its position + 1; 0 is the overload
    /// without numbers) in bits 32-39 and the input age in the top 24.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: The action's id, origin and input age.
    ///   - actionIndex: The action's interned index (`ActionRunKey.index`; 0 when none was interned).
    ///   - entrypoint: The fixed position of the run's `ActionEntrypoint` case (`ActionEntrypoint.tracePosition`).
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: ActionSignpostMessage, actionIndex: UInt32,
                      entrypoint: UInt8) -> SignpostInterval {
        beginAction(name, message, actionIndex: actionIndex, entrypointCode: Self.code(position: entrypoint))
    }

    private func beginAction(_ name: SignpostName, _ message: ActionSignpostMessage, actionIndex: UInt32,
                             entrypointCode: UInt64) -> SignpostInterval {
        let arg0 = UInt64(actionIndex) | entrypointCode << 32 | Self.inputAgeBits(milliseconds: message.inputAgeMilliseconds)
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

    /// Ends a committed interval whose end is the app's commit after it asked another process to draw (a
    /// ``SignpostName/switchTab`` to a Chromium page: the commit after `tab_activate`, before Chromium presents the
    /// tab). The end carries `end=page_activated` and the ring code `EndCode.pageActivated`, and is not mirrored to
    /// MetricKit: it is a lower bound, so readers keep it apart from app-drawn ends.
    func endPageActivated(_ name: SignpostName, _ interval: SignpostInterval) {
        signposter.endInterval(name.staticName, interval.state, "end=page_activated")
        closeInterval(name, interval, arg0: EndCode.pageActivated)
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

    /// Records one input event's ``SignpostName/inputLatency`` point event with its typed stages, formatted by the
    /// log system only when something reads them: one per input event, so no `String` is built per call.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: The event's kind, target, entrypoint, presentation source, variable refresh and stage offsets.
    public func event(_ name: SignpostName, _ message: InputLatencySignpostMessage) {
        Invariant.debugCheck(name.category == category, "signpost-category", "\(name) is not in category \(category)")
        signposter.emitEvent(
            name.staticName,
            "kind=\(message.kind, privacy: .public) target=\(message.target, privacy: .public) entry=\(message.entrypoint, privacy: .public) source=\(message.presentationSource, privacy: .public) vrr=\(message.variableRefresh ? 1 : 0, privacy: .public) coalesced=\(message.coalescedCount, privacy: .public) frame=\(message.causedFrameUpdate ? 1 : 0, privacy: .public) gen_ns=\(message.generatedNanos, privacy: .public) last_gen_us=\(message.lastGeneratedMicros, privacy: .public) arrived_us=\(message.arrivedMainMicros, privacy: .public) dispatch_start_us=\(message.dispatchStartMicros, privacy: .public) ti_start_us=\(message.textInputStartMicros, privacy: .public) ti_end_us=\(message.textInputEndMicros, privacy: .public) dispatch_end_us=\(message.dispatchEndMicros, privacy: .public) commit_us=\(message.mainCommitMicros, privacy: .public) content_us=\(message.contentSubmittedMicros, privacy: .public) daemon_us=\(message.daemonReceivedMicros, privacy: .public) pty_us=\(message.ptyWrittenMicros, privacy: .public) echo_read_us=\(message.echoReadMicros, privacy: .public) echo_sent_us=\(message.echoSentMicros, privacy: .public) presented_us=\(message.presentedMicros, privacy: .public)"
        )
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

    /// Records one input wait for Ghostty's terminal lock (``SignpostName/ghosttyLockWait``), formatted by the log
    /// system only when something reads it (`wait_us=<wait>`), so the key handler that waited builds no `String`.
    /// The ring record is an instant with the wait in ns in `arg0`.
    ///
    /// - Parameter nanos: The wait.
    public func ghosttyLockWait(nanos: UInt64) {
        Invariant.debugCheck(SignpostName.ghosttyLockWait.category == category, "ghostty-lock-wait-category",
                             "ghostty.lock_wait is not in category \(category)")
        signposter.emitEvent(SignpostName.ghosttyLockWait.staticName, "wait_us=\(nanos / 1_000, privacy: .public)")
        trace.event(.ghosttyLockWait, arg0: nanos)
    }

    /// Now on the clock ``SignpostInterval/beginUptimeNanos`` reads, so an end measures its interval with one read.
    public func nowNanos() -> UInt64 { clock.nowNanos() }

    /// Records one late commit during motion (``SignpostName/motionLateCommits``), formatted by the log system only
    /// when something reads it (`late_ms=<lateness, 3 decimals> turn_ms=<turn, 3 decimals>`). The ring record holds
    /// both in microseconds.
    ///
    /// - Parameters:
    ///   - lateMilliseconds: How long past its turn's deadline the commit ended.
    ///   - turnMilliseconds: The run-loop turn's start to the commit's end.
    public func lateCommit(lateMilliseconds: Double, turnMilliseconds: Double) {
        Invariant.debugCheck(SignpostName.motionLateCommits.category == category, "motion-late-commits-category",
                             "motion.late_commits is not in category \(category)")
        signposter.emitEvent(
            SignpostName.motionLateCommits.staticName,
            "late_ms=\(lateMilliseconds, format: .fixed(precision: 3), privacy: .public) turn_ms=\(turnMilliseconds, format: .fixed(precision: 3), privacy: .public)"
        )
        trace.event(.motionLateCommits, arg0: Self.microseconds(lateMilliseconds), arg1: Self.microseconds(turnMilliseconds))
    }

    /// Records an action run's estimated present (``SignpostName/actionPresentedEstimate``), formatted by the log
    /// system only when something reads it (`id=<id> present_ms=<ms> commit_ms=<ms> input_age_ms=<age>
    /// phase=<phase>`, 3 decimals; the age 2). The ring record is an instant with the "estimated" flag.
    ///
    /// - Parameter message: The run's fields.
    public func presentEstimate(_ message: ActionPresentSignpostMessage) {
        Invariant.debugCheck(SignpostName.actionPresentedEstimate.category == category, "action-presented-estimate-category",
                             "action.presented_estimate is not in category \(category)")
        signposter.emitEvent(
            SignpostName.actionPresentedEstimate.staticName,
            "id=\(message.id, privacy: .public) present_ms=\(message.presentMilliseconds, format: .fixed(precision: 3), privacy: .public) commit_ms=\(message.commitMilliseconds, format: .fixed(precision: 3), privacy: .public) input_age_ms=\(message.inputAgeMilliseconds, format: .fixed(precision: 2), privacy: .public) phase=\(message.phase.rawValue, privacy: .public)"
        )
        trace.event(.actionPresentedEstimate, arg0: message.traceArg0, arg1: message.estimateUptimeNanos, estimated: true)
    }

    /// Whole microseconds of a non-negative duration in milliseconds (0 for a negative or non-finite one).
    static func microseconds(_ milliseconds: Double) -> UInt64 {
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        return UInt64(min(milliseconds * 1_000, Double(UInt64.max >> 1)))
    }

    /// Begins the log system's interval with `beginInterval`, the MetricKit mirror's and, while the name's
    /// category is on, the ring's slice with `arg0` (and `arg1`, which only a thread slice has free: an async
    /// slice's `arg1` is its id). With `traced` false the ring takes no slice whatever the flags are (a name that
    /// also needs a recording-only category on: ``beginCEFPump(reasonCode:)``).
    func openInterval(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0, traced: Bool = true,
                      _ beginInterval: (OSSignpostID) -> OSSignpostIntervalState) -> SignpostInterval {
        Invariant.debugCheck(name.category == category, "interval-category", "\(name) is not in category \(category)")
        Invariant.debugCheck(arg1 == 0 || name.opensThreadSlice, "async-slice-arg1",
                             "\(name) is an async slice: its arg1 is the async id")
        let id = signposter.makeSignpostID()
        let beginNanos = clock.nowNanos()
        let state = beginInterval(id)
        return SignpostInterval(state: state, metricKitID: mirror.begin(name), beginUptimeNanos: beginNanos,
                                ring: traced ? traceBegin(name, id: id, beginNanos: beginNanos, arg0: arg0, arg1: arg1) : nil)
    }
}
