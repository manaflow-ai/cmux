import Foundation
import Network
import Testing
@testable import CmuxNextRemoteLocalhost

/// The proxy's trust check is a run of blocking `proc_pid*` calls. It runs one at a time on its own queue, so
/// a flood of local connections neither holds cooperative-pool threads nor runs many scans at once, and a wait
/// for it is bounded: a stalled scan cannot hold the connections queued behind it.
nonisolated struct PeerProcessScanTests {
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private var _peak = 0
        private var _started = 0
        private let release = DispatchSemaphore(value: 0)
        private let stalledStarted = DispatchSemaphore(value: 0)

        var peak: Int { lock.withLock { _peak } }
        var started: Int { lock.withLock { _started } }

        func slowScan() -> Bool {
            lock.withLock {
                running += 1
                _started += 1
                _peak = max(_peak, running)
            }
            usleep(20_000)
            lock.withLock { running -= 1 }
            return true
        }

        /// A scan that does not finish until `unblock()`.
        func stalledScan() -> Bool {
            lock.withLock { _started += 1 }
            stalledStarted.signal()
            release.wait()
            return true
        }

        func unblock() { release.signal() }

        /// Returns once a stalled scan is running on the queue (without holding a cooperative thread).
        func waitUntilStalled() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    self.stalledStarted.wait()
                    continuation.resume()
                }
            }
        }
    }

    private static func check(_ scan: PeerScan, timeout: Duration = .seconds(5),
                              _ work: @escaping @Sendable () -> Bool) async -> Bool {
        await scan.run(timeout: timeout, work)
    }

    @Test func scansRunOneAtATime() async {
        let gauge = Gauge()
        let scan = PeerScan(limit: 100)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { await Self.check(scan) { gauge.slowScan() } } }
            for await trusted in group { #expect(trusted) }
        }
        #expect(gauge.started == 32)
        #expect(gauge.peak == 1, "\(gauge.peak) scans ran at once")
    }

    /// With 64 scans pending, the cooperative pool still runs other work: a canary task finishes long before
    /// the scans (64 x 20 ms) do.
    @Test func pendingScansDoNotStarveTheCooperativePool() async {
        let gauge = Gauge()
        let scan = PeerScan(limit: 100)
        let started = ContinuousClock.now
        var canaryDuration = Duration.zero
        await withTaskGroup(of: Duration?.self) { group in
            for _ in 0..<64 { group.addTask { _ = await Self.check(scan) { gauge.slowScan() }; return nil } }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                return ContinuousClock.now - started
            }
            for await finished in group { if let finished { canaryDuration = finished } }
        }
        #expect(canaryDuration < .milliseconds(600), "the canary waited \(canaryDuration) behind the scans")
        #expect(gauge.started == 64)
    }

    /// One scan stalls. The callers behind it answer "not trusted" when their wait runs out, and their scans
    /// are skipped, so they hold no connection slot and add no work once the stall ends.
    @Test func aStalledScanDoesNotHoldTheCallersBehindIt() async {
        let gauge = Gauge()
        let scan = PeerScan()
        let stalled = Task { await Self.check(scan, timeout: .seconds(30)) { gauge.stalledScan() } }
        await gauge.waitUntilStalled()
        let started = ContinuousClock.now
        let answers = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<5 { group.addTask { await Self.check(scan, timeout: .milliseconds(150)) { gauge.slowScan() } } }
            var all: [Bool] = []
            for await answer in group { all.append(answer) }
            return all
        }
        #expect(answers == [Bool](repeating: false, count: 5))
        #expect(ContinuousClock.now - started < .seconds(2), "the callers waited for the stalled scan")
        gauge.unblock()
        #expect(await stalled.value)
        // The queue is serial: when this sentinel answers, everything queued before it has run or been skipped.
        let sentinel = await Self.check(scan) { true }
        #expect(sentinel)
        #expect(gauge.started == 1, "\(gauge.started) scans started; the timed-out ones must be skipped")
    }

    @Test func aCancelledCallerAnswersAtOnceAndItsScanIsSkipped() async {
        let gauge = Gauge()
        let scan = PeerScan()
        let blocker = Task { await Self.check(scan, timeout: .seconds(30)) { gauge.stalledScan() } }
        await gauge.waitUntilStalled()
        let waiter = Task { await Self.check(scan, timeout: .seconds(30)) { gauge.slowScan() } }
        // Cancelling before the waiter reaches the queue is fine too: it answers false either way.
        waiter.cancel()
        #expect(await waiter.value == false)
        gauge.unblock()
        #expect(await blocker.value)
        let sentinel = await Self.check(scan) { true }
        #expect(sentinel)
        #expect(gauge.started == 1, "the cancelled caller's scan ran")
    }

    /// Past the pending limit a caller is untrusted at once instead of queueing another block behind a stall.
    @Test func callersPastThePendingLimitAnswerAtOnce() async {
        let gauge = Gauge()
        let scan = PeerScan()
        let stalled = Task { await Self.check(scan, timeout: .seconds(30)) { gauge.stalledScan() } }
        await gauge.waitUntilStalled()
        let extra = 10
        let waiting = PeerScan.pendingLimit - 1
        let started = ContinuousClock.now
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<(waiting + extra) { group.addTask { await Self.check(scan, timeout: .seconds(30)) { gauge.slowScan() } } }
            // The ones refused return at once; the admitted ones wait on the stall (30 s timeout).
            var refused = 0
            for await answer in group {
                #expect(!answer)
                refused += 1
                if refused == extra { break }
            }
            #expect(ContinuousClock.now - started < .seconds(5), "the refused callers waited for the stall")
            group.cancelAll()
            for await _ in group {}
        }
        gauge.unblock()
        #expect(await stalled.value)
        let sentinel = await Self.check(scan) { true }
        #expect(sentinel)
        #expect(gauge.started == 1, "queued scans ran")
    }

    @Test func aPeerThatIsNotThisProcessIsNotTrusted() async {
        let trusted = await PeerScan().isTrusted(peerHost: .ipv4(.loopback), peerPort: 1, localHost: .ipv4(.loopback),
                                                         localPort: 2)
        #expect(!trusted)
    }
}
