import CmuxSafeConcurrency
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// Blocks a lane was given, held until the test runs them, and the events their captures sent.
private final class HeldLane: Sendable {
    private let blocks = Mutex<[@Sendable () -> Void]>([])
    private let sent = Mutex<[Event]>([])
    private let stackWalks = Mutex(0)

    var lane: InvariantSink.Lane {
        { block in self.blocks.withLock { $0.append(block) } }
    }

    var capture: InvariantSink.Capture {
        { event in self.sent.withLock { $0.append(event) } }
    }

    var stack: @Sendable () -> [UInt] {
        { self.stackWalks.withLock { $0 += 1 }; return [] }
    }

    var held: Int { blocks.withLock { $0.count } }
    var events: [Event] { sent.withLock { $0 } }
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

/// p10-stability-099: the app's invariant sink builds and sends nothing on the failing thread (only a stack walk
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
