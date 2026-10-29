import CmuxSafeConcurrency
import Dispatch
import Testing

/// The events a sink under test took, in order.
private final class EventLog: InvariantEventSink {
    private let events = Mutex<[InvariantEvent]>([])

    func deliver(_ event: InvariantEvent) {
        events.withLock { $0.append(event) }
    }

    var recorded: [InvariantEvent] {
        events.withLock { $0 }
    }

    var sites: [String] {
        recorded.map(\.site)
    }
}

/// A count threads share.
private final class Counter: Sendable {
    private let count = Mutex(0)

    func add() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

/// The Invariant API's report tiers: a failing site reports once per launch through the
/// installed sink, on the failing thread and without blocking; notFatalUntil traps only from its named build on.
/// The trap tier runs end to end in ``InvariantTrapTests``.
@Suite struct InvariantTests {
    @Test func aHoldingConditionReportsNothing() {
        let invariant = Invariant(capacity: 8)
        let log = EventLog()
        #expect(invariant.install(build: 10, sink: log))
        #expect(!Invariant.notFatalUntil(true, "holds", build: 100, in: invariant))
        #expect(!Invariant.dumpWillBeCheck(true, "holds", in: invariant))
        #expect(log.recorded.isEmpty)
    }

    @Test func oneEventPerSitePerLaunch() {
        let invariant = Invariant(capacity: 8)
        let log = EventLog()
        invariant.install(build: 10, sink: log)
        var first: [Bool] = []
        for _ in 0 ..< 5 {
            first.append(Invariant.notFatalUntil(false, "repeated", build: 100, in: invariant))
        }
        #expect(first == [true, false, false, false, false])
        #expect(log.recorded.count == 1)
        #expect(log.recorded.first?.kind == .notFatalUntil(build: 100))
        #expect(log.recorded.first?.id.description == "repeated")
    }

    @Test func eachSiteReportsOnItsOwn() {
        let invariant = Invariant(capacity: 8)
        let log = EventLog()
        invariant.install(build: 10, sink: log)
        Invariant.notFatalUntil(false, "same-name", build: 100, in: invariant)
        Invariant.notFatalUntil(false, "same-name", build: 100, in: invariant)
        Invariant.dumpWillBeCheck(false, "other-name", in: invariant)
        #expect(log.recorded.count == 3, "two lines with one name are two sites")
        #expect(Set(log.sites).count == 3)
        #expect(log.recorded.last?.kind == .dumpWillBeCheck)
    }

    @Test func racingFailuresOfOneSiteReportOnce() {
        let invariant = Invariant(capacity: 64)
        let log = EventLog()
        invariant.install(build: 10, sink: log)
        let claims = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if Invariant.dumpWillBeCheck(false, "racing", in: invariant) { claims.add() }
        }
        #expect(claims.value == 1)
        #expect(log.recorded.count == 1)
    }

    @Test func theSinkTakesTheEventInTheFailingCall() {
        let invariant = Invariant(capacity: 8)
        let log = EventLog()
        invariant.install(build: 10, sink: log)
        Invariant.notFatalUntil(false, "in-call", build: 100, in: invariant)
        #expect(log.recorded.count == 1, "the hand-off is synchronous: the sink owns the move off the thread")
    }

    @Test func withoutASinkAFailureIsClaimedAndCounted() {
        let invariant = Invariant(capacity: 8)
        #expect(invariant.runningBuild == nil)
        var first: [Bool] = []
        for _ in 0 ..< 3 {
            // One site, past its build: with no running build installed it never traps.
            first.append(Invariant.notFatalUntil(false, "no-sink", build: 1, in: invariant))
        }
        #expect(first == [true, false, false])
        #expect(invariant.undeliveredCount == 1)
    }

    @Test func theFirstInstallStays() {
        let invariant = Invariant(capacity: 8)
        let first = EventLog()
        let second = EventLog()
        #expect(invariant.install(build: 7, sink: first))
        #expect(!invariant.install(build: 9, sink: second))
        #expect(invariant.runningBuild == 7)
        Invariant.dumpWillBeCheck(false, "first-sink", in: invariant)
        #expect(first.recorded.count == 1)
        #expect(second.recorded.isEmpty)
    }

    @Test func aFullTableDropsAndCountsNewSites() {
        let invariant = Invariant(capacity: 2)
        let log = EventLog()
        invariant.install(build: 10, sink: log)
        #expect(invariant.capacity == 2)
        Invariant.dumpWillBeCheck(false, "one", in: invariant)
        Invariant.dumpWillBeCheck(false, "two", in: invariant)
        Invariant.dumpWillBeCheck(false, "three", in: invariant)
        #expect(log.recorded.count == 2)
        #expect(invariant.droppedCount == 1)
    }

    @Test func notFatalUntilTrapsFromItsBuildOn() {
        #expect(!Invariant.traps(fatalFrom: 100, runningBuild: nil), "an unknown build never traps")
        #expect(!Invariant.traps(fatalFrom: 100, runningBuild: 99))
        #expect(Invariant.traps(fatalFrom: 100, runningBuild: 100))
        #expect(Invariant.traps(fatalFrom: 100, runningBuild: 101))
    }

    @Test func belowItsBuildNotFatalUntilReportsAndReturns() {
        let invariant = Invariant(capacity: 8)
        let log = EventLog()
        invariant.install(build: 99, sink: log)
        #expect(Invariant.notFatalUntil(false, "below-build", build: 100, in: invariant))
        #expect(log.recorded.first?.message.hasPrefix("invariant below-build failed at CmuxSafeConcurrencyTests/") == true)
    }
}

/// One `notFatalUntil` site whose fatal build the caller picks, so a test can fail the same site below and then
/// at its build.
private func failOneSite(fatalFrom build: UInt64, in invariant: Invariant) -> Bool {
    Invariant.notFatalUntil(false, "one-site", build: build, in: invariant)
}

/// The trap tier end to end: each body runs in its own child process, which must stop.
#if os(macOS) || os(Linux)
@Suite struct InvariantTrapTests {
    @Test func aFailedCheckStopsTheProcessInEveryBuild() async {
        await #expect(processExitsWith: .failure) {
            Invariant.check(false, "check-traps")
        }
    }

    @Test func notFatalUntilStopsTheProcessAtItsBuild() async {
        await #expect(processExitsWith: .failure) {
            let invariant = Invariant(capacity: 8)
            invariant.install(build: 100, sink: EventLog())
            Invariant.notFatalUntil(false, "at-build", build: 100, in: invariant)
        }
    }

    @Test func notFatalUntilStopsTheProcessPastItsBuild() async {
        await #expect(processExitsWith: .failure) {
            let invariant = Invariant(capacity: 8)
            invariant.install(build: 101, sink: EventLog())
            Invariant.notFatalUntil(false, "past-build", build: 100, in: invariant)
        }
    }

    @Test func aSiteThatAlreadyReportedStillStopsTheProcessAtItsBuild() async {
        await #expect(processExitsWith: .failure) {
            let invariant = Invariant(capacity: 8)
            invariant.install(build: 100, sink: EventLog())
            // Below its build: the site reports, is claimed, and the call returns.
            _ = failOneSite(fatalFrom: 101, in: invariant)
            // The same site at its build: the trap is decided before the claim, so it stops the process.
            _ = failOneSite(fatalFrom: 100, in: invariant)
        }
    }
}
#endif
