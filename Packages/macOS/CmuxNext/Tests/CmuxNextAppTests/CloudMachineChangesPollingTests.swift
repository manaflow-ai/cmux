import CmuxNextCloud
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudMachineChangesPollingTests {
    /// The test advances each delay explicitly; no wall-clock waiting or polling.
    @MainActor private final class Sleeper {
        var durations: [Duration] = []
        private var pending: CheckedContinuation<Void, any Error>?
        private var observer: CheckedContinuation<Duration, Never>?

        func sleep(_ duration: Duration) async throws {
            durations.append(duration)
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                observer?.resume(returning: duration)
                observer = nil
            }
        }

        func next() async -> Duration {
            if pending != nil { return durations.last! }
            return await withCheckedContinuation { observer = $0 }
        }

        func advance() {
            let continuation = pending
            pending = nil
            continuation?.resume()
        }
    }

    @MainActor private final class Signal {
        private var sent = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if sent { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func send() {
            sent = true
            waiter?.resume()
            waiter = nil
        }
    }

    @MainActor private final class RefreshGate {
        let entered = Signal()
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation {
                continuation = $0
                entered.send()
            }
        }
        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aLongTransitionKeepsRefreshingBeyondTheOldFortyReadLimit() async {
        let sleeper = Sleeper()
        let changes = CloudMachineChanges(sleep: { try await sleeper.sleep($0) })
        var reads = 0
        changes.began {
            reads += 1
            changes.listed([CloudMachine(id: "slow", status: .deleting)]) {}
        }
        for _ in 0..<45 {
            #expect(await sleeper.next() == .seconds(3))
            sleeper.advance()
        }
        _ = await sleeper.next()
        #expect(reads == 45)
        #expect(changes.isSettling)
        changes.stop()
        sleeper.advance()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedReadsBackOffAndRecoverWithoutAnActivationEvent() async {
        let sleeper = Sleeper()
        let changes = CloudMachineChanges(sleep: { try await sleeper.sleep($0) })
        var reads = 0
        changes.began {
            reads += 1
            // Failed refreshes do not deliver a list. A later successful list
            // restores the usual cadence while its provider operation is pending.
            if reads == 6 {
                changes.listed([CloudMachine(id: "slow", status: .starting)]) {}
            }
        }
        for delay in [3, 6, 12, 24, 30, 30] {
            #expect(await sleeper.next() == .seconds(delay))
            sleeper.advance()
        }
        #expect(await sleeper.next() == .seconds(3))
        #expect(reads == 6)
        changes.listed([CloudMachine(id: "slow", status: .running)]) {}
        #expect(!changes.isSettling, "a terminal record ends the retry lifecycle")
        sleeper.advance()
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingCancelsTheDelayAndLateListsCannotRestartIt() async {
        let sleeper = Sleeper()
        let changes = CloudMachineChanges(sleep: { try await sleeper.sleep($0) })
        var reads = 0
        changes.began { reads += 1 }
        _ = await sleeper.next()
        changes.stop()
        changes.listed([CloudMachine(id: "slow", status: .pausing)]) { reads += 1 }
        changes.began { reads += 1 }
        #expect(!changes.isSettling)
        sleeper.advance()
        // Even an injected sleeper that returns normally on cancellation cannot refresh.
        await Task.yield()
        #expect(reads == 0)
        #expect(sleeper.durations.count == 1)
    }
    @Test(.timeLimit(.minutes(1)))
    func aSettledListCancelsTheScheduledRead() async {
        let sleeper = Sleeper()
        let changes = CloudMachineChanges(sleep: { try await sleeper.sleep($0) })
        var reads = 0
        changes.listed([CloudMachine(id: "slow", status: .starting)]) { reads += 1 }
        _ = await sleeper.next()
        changes.listed([CloudMachine(id: "slow", status: .running)]) {}
        #expect(!changes.isSettling)
        sleeper.advance()
        await Task.yield()
        #expect(reads == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func anOldRefreshCannotSettleTheRunStartedAfterStop() async {
        let sleeper = Sleeper(), gate = RefreshGate(), finished = Signal()
        let changes = CloudMachineChanges(sleep: { try await sleeper.sleep($0) })
        changes.began {
            await gate.wait()
            changes.listed([CloudMachine(id: "old", status: .running)]) {}
            finished.send()
        }
        _ = await sleeper.next()
        sleeper.advance()
        await gate.entered.wait()
        changes.stop()
        changes.start()
        var newReads = 0
        changes.began {
            newReads += 1
            changes.listed([CloudMachine(id: "new", status: .pausing)]) {}
        }
        _ = await sleeper.next()
        gate.open()
        await finished.wait()
        #expect(changes.isSettling, "the old settled list must not cancel the new run")
        sleeper.advance()
        _ = await sleeper.next()
        #expect(newReads == 1)
        changes.stop()
        sleeper.advance()
    }

    @Test(.timeLimit(.minutes(1)))
    func aChangeBegunDuringARefreshNeedsItsOwnLaterRead() async {
        let sleeper = Sleeper(), gate = RefreshGate(), oldFinished = Signal(), settled = Signal()
        let changes = CloudMachineChanges(sleep: { try await sleeper.sleep($0) })
        var reads = 0
        changes.began {
            reads += 1
            await gate.wait()
            changes.listed([CloudMachine(id: "slow", status: .running)]) {}
            oldFinished.send()
        }
        _ = await sleeper.next()
        sleeper.advance()
        await gate.entered.wait()
        changes.began {
            reads += 1
            changes.listed([CloudMachine(id: "slow", status: .paused)]) {}
            settled.send()
        }
        gate.open()
        await oldFinished.wait()
        #expect(await sleeper.next() == .seconds(3))
        #expect(changes.isSettling, "the earlier read cannot settle the newer operation")
        sleeper.advance()
        await settled.wait()
        #expect(reads == 2)
        #expect(!changes.isSettling)
    }

}
