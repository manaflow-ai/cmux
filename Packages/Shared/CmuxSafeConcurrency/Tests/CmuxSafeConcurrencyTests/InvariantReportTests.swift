import CmuxSafeConcurrency
import Testing

/// The events a sink under test took, in order.
private final class ReportLog: InvariantEventSink {
    private let events = Mutex<[InvariantEvent]>([])

    func deliver(_ event: InvariantEvent) {
        events.withLock { $0.append(event) }
    }

    var recorded: [InvariantEvent] {
        events.withLock { $0 }
    }
}

/// How many times a condition was evaluated.
private final class Evaluations: Sendable {
    private let count = Mutex(0)

    func holds(_ value: Bool) -> Bool {
        count.withLock { $0 += 1 }
        return value
    }

    var value: Int {
        count.withLock { $0 }
    }
}

#if INVARIANT_REPORT
/// The nightly-assert variant (p10-stability-202): an -O build with `-DINVARIANT_REPORT`, where debug checks and
/// `assert()` report each failing site once per launch and never trap. Run with
/// `swift test -c release -Xswiftc -DINVARIANT_REPORT --filter InvariantReportTests`.
@Suite struct InvariantReportTests {
    @Test func thisIsTheNightlyAssertVariant() {
        #expect(Invariant.reportsDebugChecks)
        #expect(Invariant.reportBuildMarker.description.hasPrefix("CMUX_INVARIANT_REPORT_BUILD"))
    }

    @Test func aFailedDebugCheckReportsOncePerSiteAndGoesOn() {
        let invariant = Invariant(capacity: 8)
        let log = ReportLog()
        invariant.install(build: 10, sink: log)
        for _ in 0 ..< 5 {
            Invariant.debugCheck(false, "debug-repeated", in: invariant)
        }
        Invariant.debugCheck(false, "debug-other", in: invariant)
        #expect(log.recorded.count == 2, "one event per site per launch")
        #expect(log.recorded.first?.kind == .debugCheck)
        #expect(log.recorded.first?.id.description == "debug-repeated")
    }

    @Test func aHoldingDebugCheckIsEvaluatedAndReportsNothing() {
        let invariant = Invariant(capacity: 8)
        let log = ReportLog()
        invariant.install(build: 10, sink: log)
        let evaluations = Evaluations()
        Invariant.debugCheck(evaluations.holds(true), "debug-holds", in: invariant)
        #expect(evaluations.value == 1)
        #expect(log.recorded.isEmpty)
    }

    /// The only test of this process that installs into ``Invariant/process``: `assert()` reports there.
    @Test func assertInAFileThatImportsTheModuleReportsOncePerSite() {
        let log = ReportLog()
        #expect(Invariant.process.install(build: nil, sink: log))
        for _ in 0 ..< 3 {
            assert(false, "nightly-assert reports this")
        }
        assertionFailure("and this")
        #expect(log.recorded.count == 2, "one event per site per launch")
        #expect(log.recorded.allSatisfy { $0.kind == .assertion })
        #expect(log.recorded.first?.id.description == "assert")
        #expect(log.recorded.last?.id.description == "assertionFailure")
    }
}
#else
/// Outside the nightly-assert variant, ``Invariant/debugCheck(_:_:in:fileID:line:)`` is `assert()`: it traps in a
/// Debug build and is compiled out of an -O build (p10-stability-202).
@Suite struct InvariantReportTests {
    @Test func thisIsNotTheNightlyAssertVariant() {
        #expect(!Invariant.reportsDebugChecks)
    }

    @Test func aHoldingDebugCheckReportsNothing() {
        let invariant = Invariant(capacity: 8)
        let log = ReportLog()
        invariant.install(build: 10, sink: log)
        Invariant.debugCheck(true, "debug-holds", in: invariant)
        #expect(log.recorded.isEmpty)
    }

    #if !DEBUG
    @Test func anOptimizedBuildDoesNotEvaluateADebugCheck() {
        let invariant = Invariant(capacity: 8)
        let log = ReportLog()
        invariant.install(build: 10, sink: log)
        let evaluations = Evaluations()
        Invariant.debugCheck(evaluations.holds(false), "debug-compiled-out", in: invariant)
        #expect(evaluations.value == 0)
        #expect(log.recorded.isEmpty)
    }
    #endif

    #if DEBUG && (os(macOS) || os(Linux))
    @Test func aFailedDebugCheckStopsADebugBuild() async {
        await #expect(processExitsWith: .failure) {
            Invariant.debugCheck(false, "debug-traps")
        }
    }
    #endif
}
#endif
