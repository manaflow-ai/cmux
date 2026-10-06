import Foundation
import Synchronization
import Testing
import CmuxNextWakeups
@testable import CmuxNextResources

/// A clock whose sleeps end only when the test advances it.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex<(now: Instant, sleepers: [UUID: Sleeper])>((Instant(offset: .zero), [:]))
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready = state.withLock { state -> Bool in
                    if deadline <= state.now { return true }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for key in due.keys { state.sleepers[key] = nil }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Lets 10 000 turns pass (no condition): work that must NOT happen gets
/// every chance to run before the test checks it did not.
@MainActor
private func drainTurns() async {
    for _ in 0..<10_000 { await Task.yield() }
}

/// Waits up to 10 000 turns; a timeout records an Issue at the caller with the time waited.
@MainActor
private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () -> Bool) async {
    let start = ContinuousClock.now
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    if !condition() {
        Issue.record("waitUntil gave up after 10000 turns (\(ContinuousClock.now - start)): the condition at \(sourceLocation.fileName):\(sourceLocation.line) never held",
                     sourceLocation: sourceLocation)
    }
}

/// Counts calls; each call reports one process that used 0.25 s of CPU per call.
@MainActor
private final class CountingSource: ResourceSampleSource {
    var calls = 0
    var targets: [ResourceTarget] = []

    func sample(_ target: ResourceTarget) async -> ResourceSampleSet {
        calls += 1
        targets.append(target)
        let key = ProcessKey(pid: 42)
        let time = UInt64(calls) * 1_000_000_000
        return ResourceSampleSet(
            tabs: [TabResourceSources(tabID: "t", title: "t", kind: .terminal, processes: [key])],
            samples: [key: ProcessSample(key: key, name: "zsh", cpuNanos: UInt64(calls) * 250_000_000, memoryBytes: 1_000, sampledAtNanos: time)]
        )
    }
}

@MainActor
@Suite struct ResourceCardSamplerTests {
    @Test func samplesAtOpenThenOncePerIntervalWhileOpen() async {
        let clock = ManualClock()
        let source = CountingSource()
        let sampler = ResourceCardSampler(source: source, interval: .seconds(1),
                                          timer: DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger()))
        var reports: [ResourceReport] = []
        sampler.open(.tab("t")) { reports.append($0) }
        await waitUntil { source.calls == 1 && clock.sleeperCount == 1 }
        #expect(source.calls == 1)
        #expect(reports.last?.tabs.first?.usage.cpu == nil)
        #expect(reports.last?.tabs.first?.usage.memoryBytes == 1_000)

        clock.advance(by: .seconds(1))
        await waitUntil { source.calls == 2 && clock.sleeperCount == 1 }
        #expect(source.calls == 2)
        #expect(reports.last?.tabs.first?.usage.cpu == 0.25)
        #expect(source.targets == [.tab("t"), .tab("t")])
    }

    @Test func closingTheCardStopsSampling() async {
        let clock = ManualClock()
        let source = CountingSource()
        let sampler = ResourceCardSampler(source: source, interval: .seconds(1),
                                          timer: DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger()))
        var updates = 0
        sampler.open(.workspace("w")) { _ in updates += 1 }
        await waitUntil { clock.sleeperCount == 1 }
        sampler.close()
        #expect(!sampler.isOpen)
        #expect(!sampler.isScheduled)
        await waitUntil { clock.sleeperCount == 0 }
        #expect(clock.sleeperCount == 0)
        let callsAtClose = source.calls
        let updatesAtClose = updates
        for _ in 0..<5 { clock.advance(by: .seconds(1)) }
        await drainTurns()
        #expect(source.calls == callsAtClose)
        #expect(updates == updatesAtClose)
    }

    @Test func aSampleInFlightWhenTheCardClosesIsDropped() async {
        let clock = ManualClock()
        let source = CountingSource()
        let sampler = ResourceCardSampler(source: source, interval: .seconds(1),
                                          timer: DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger()))
        var updates = 0
        sampler.open(.tab("t")) { _ in updates += 1 }
        // Close before the first sample's task ran.
        sampler.close()
        await drainTurns()
        #expect(updates == 0)
        #expect(!sampler.isScheduled)
        #expect(clock.sleeperCount == 0)
    }

    @Test func reopeningTheSameTargetKeepsSamplingWithoutARestart() async {
        let clock = ManualClock()
        let source = CountingSource()
        let sampler = ResourceCardSampler(source: source, interval: .seconds(1),
                                          timer: DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger()))
        sampler.open(.tab("t")) { _ in }
        await waitUntil { source.calls == 1 && clock.sleeperCount == 1 }
        var got: ResourceReport?
        sampler.open(.tab("t")) { got = $0 }
        #expect(source.calls == 1)
        #expect(got != nil)
    }
}
