import CmuxSafeConcurrency
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#endif
import Dispatch
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// What a test reads of one sent Sentry `Event` (a class that is not Sendable), copied in the capture.
private struct SentEvent: Sendable {
    let level: SentryLevel
    let fingerprint: [String]?
    let tags: [String: String]?
    let exceptionType: String?
    /// Whether the capture ran on the main thread.
    let onMainThread: Bool

    init(_ event: Event) {
        level = event.level
        fingerprint = event.fingerprint
        tags = event.tags
        exceptionType = event.exceptions?.first?.type
        onMainThread = Thread.isMainThread
    }
}

/// The events a sink's captures sent, as ``SentEvent``s.
private final class SentEvents: Sendable {
    private let sent = CmuxSafeConcurrency.Mutex<[SentEvent]>([])

    var capture: InvariantSink.Capture {
        { event in
            let copy = SentEvent(event)
            self.sent.withLock { $0.append(copy) }
        }
    }

    var events: [SentEvent] { sent.withLock { $0 } }
}

/// Blocks a lane was given, held until the test runs them, and the events their captures sent.
private final class HeldLane: Sendable {
    private let blocks = CmuxSafeConcurrency.Mutex<[@Sendable () -> Void]>([])
    private let sent = SentEvents()
    private let stackWalks = CmuxSafeConcurrency.Mutex(0)

    var lane: InvariantSink.Lane {
        { block in self.blocks.withLock { $0.append(block) } }
    }

    var capture: InvariantSink.Capture { sent.capture }

    var stack: @Sendable () -> [UInt] {
        { self.stackWalks.withLock { $0 += 1 }; return [] }
    }

    var held: Int { blocks.withLock { $0.count } }
    var events: [SentEvent] { sent.events }
    var walks: Int { stackWalks.withLock { $0 } }

    func runHeld() {
        let run = blocks.withLock { blocks in
            let run = blocks
            blocks = []
            return run
        }
        for block in run { block() }
    }
}

/// The app's invariant sink builds and sends nothing on the failing thread (only a stack walk
/// and one enqueue), sends one event per site per launch, and sends nothing while crash reporting is off.
@Suite struct InvariantSinkTests {
    @Test func theFailingThreadOnlyEnqueues() {
        let held = HeldLane()
        let invariant = Invariant(capacity: 8)
        invariant.install(build: 10, sink: InvariantSink(sends: true, lane: held.lane, capture: held.capture,
                                                         stack: held.stack))
        Invariant.notFatalUntil(false, "sink-enqueues", build: 100, in: invariant)
        #expect(held.events.isEmpty, "no event built or sent on the caller's thread")
        #expect(held.held == 1)
        #expect(held.walks == 1)
        held.runHeld()
        #expect(held.events.count == 1, "the lane sends it")
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The real caller path (the default stack walk and a real DispatchQueue lane) on the main thread makes no
    /// blocking call the detector sees, and the event is built and captured off the main thread.
    @MainActor @Test func theMainThreadCallerDoesNoBlockingWork() async {
        let queue = DispatchQueue(label: "test.invariant-sink.lane", qos: .utility)
        let sent = SentEvents()
        let invariant = Invariant(capacity: 8)
        invariant.install(build: 10, sink: InvariantSink(sends: true, lane: { queue.async(execute: $0) },
                                                         capture: sent.capture))
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            Invariant.notFatalUntil(false, "sink-main-thread", build: 100, in: invariant)
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty, "the failing call blocked the main thread")
        await withCheckedContinuation { (drained: CheckedContinuation<Void, Never>) in
            queue.async { drained.resume() }
        }
        #expect(sent.events.count == 1, "the lane sends it")
        #expect(sent.events.first?.onMainThread == false, "the event was captured on the main thread")
    }
    #endif

    @Test func oneEventPerSitePerLaunch() {
        let held = HeldLane()
        let invariant = Invariant(capacity: 8)
        invariant.install(build: 10, sink: InvariantSink(sends: true, lane: held.lane, capture: held.capture,
                                                         stack: held.stack))
        for _ in 0 ..< 10 {
            Invariant.dumpWillBeCheck(false, "sink-once", in: invariant)
        }
        held.runHeld()
        #expect(held.events.count == 1)
        #expect(held.walks == 1, "a repeat costs the caller no stack walk")
    }

    @Test func reportsOffSendNothingAndEnqueueNothing() {
        let held = HeldLane()
        let invariant = Invariant(capacity: 8)
        invariant.install(build: 10, sink: InvariantSink(sends: false, lane: held.lane, capture: held.capture,
                                                         stack: held.stack))
        Invariant.notFatalUntil(false, "sink-off", build: 100, in: invariant)
        #expect(held.held == 0)
        #expect(held.walks == 0)
        #expect(held.events.isEmpty)
    }

    @Test func theEventGroupsBySiteAndNamesItsTier() {
        let failure = InvariantEvent(kind: .notFatalUntil(build: 42), id: "grouped", fileID: "Module/File.swift",
                                     line: 7)
        let event = InvariantSink.event(for: failure, addresses: [])
        #expect(event.level == .error)
        #expect(event.fingerprint == ["invariant", "grouped", "Module/File.swift:7"])
        #expect(event.tags?["invariant_tier"] == "not_fatal_until")
        #expect(event.tags?["invariant_fatal_build"] == "42")
        #expect(event.exceptions?.first?.type == "InvariantFailure")
        let dump = InvariantSink.event(for: InvariantEvent(kind: .dumpWillBeCheck, id: "grouped",
                                                           fileID: "Module/File.swift", line: 7), addresses: [])
        #expect(dump.level == .warning)
        #expect(dump.tags?["invariant_tier"] == "dump_will_be_check")
    }

    @Test func theRunningBuildIsAWholeBundleVersion() {
        #expect(InvariantSink.runningBuild(bundleVersion: "2026102612301") == 2_026_102_612_301)
        #expect(InvariantSink.runningBuild(bundleVersion: "1.2.3") == nil, "a dotted DEV version never traps")
        #expect(InvariantSink.runningBuild(bundleVersion: nil) == nil)
        #expect(InvariantSink.runningBuild(bundleVersion: "") == nil)
    }

    @Test func aReporterThatDidNotStartGivesASinkThatSendsNothing() {
        let reporter = CrashReporter(policy: CrashReportingPolicy(
            bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
            telemetryOptIn: false, managedDisablesTelemetry: false, processEnvironment: [:]))
        let invariant = Invariant(capacity: 8)
        #expect(InvariantSink.install(reporter: reporter, bundleVersion: "42", into: invariant))
        #expect(invariant.runningBuild == 42)
        Invariant.dumpWillBeCheck(false, "consent-off", in: invariant)
        #expect(invariant.undeliveredCount == 0, "the sink took it and dropped it for consent")
    }
}
