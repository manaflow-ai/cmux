import CmuxNextCloud
import CmuxNextDaemon
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

    /// An `apps-cloud-machine` event as the daemon sends it.
    private static func push(_ json: String) throws -> DaemonEvent {
        .unknown(name: "apps-cloud-machine", payload: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    @Test
    func aPushedRecordReadsTheCratesEpochMillisecondTimestamps() throws {
        let changes = CloudMachineChanges(sleep: { _ in })
        var shown: CloudMachine?
        changes.startPush({ _ in }) { shown = $0 }
        changes.machineState(try Self.push("""
        {"machine":"vm-ms","kind":"record","record":{"id":"vm-ms","provider":"freestyle","status":"running",
         "servesDesktop":false,"createdAt":1700000000000,"updatedAt":1700000123456,"runningSince":1700000100000}}
        """))
        let record = try #require(shown, "a record whose timestamps are epoch milliseconds must decode")
        #expect(record.updatedAt == Date(timeIntervalSince1970: 1_700_000_123.456))
        #expect(record.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(record.runningSince == Date(timeIntervalSince1970: 1_700_000_100))
    }

    /// The watches sent to the daemon; the first one waits until the test releases it.
    @MainActor private final class Watches {
        var sent: [[String]] = []
        var gate: CheckedContinuation<Void, Never>?
        var started: CheckedContinuation<Void, Never>?
        var emptied: CheckedContinuation<Void, Never>?

        func watch(_ machines: [CloudMachine]) async {
            sent.append(machines.map(\.id))
            if sent.count == 1 {
                await withCheckedContinuation { continuation in
                    gate = continuation
                    started?.resume()
                    started = nil
                }
            }
            if machines.isEmpty {
                emptied?.resume()
                emptied = nil
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func stopDropsTheWatchesStillQueuedBehindASlowOne() async {
        let changes = CloudMachineChanges(sleep: { _ in })
        let watches = Watches()
        changes.startPush({ await watches.watch($0) }) { _ in }
        await withCheckedContinuation { continuation in
            watches.started = continuation
            changes.listed([CloudMachine(id: "a")]) {}
        }
        // A list queued behind the slow watch, then Cloud is turned off.
        changes.listed([CloudMachine(id: "b")]) {}
        changes.stop()
        await withCheckedContinuation { continuation in
            watches.emptied = continuation
            watches.gate?.resume()
            watches.gate = nil
        }
        #expect(watches.sent == [["a"], []], "a watch queued before stop must not open sockets after it")
    }

    @Test(.timeLimit(.minutes(1)))
    func aPushTheDaemonDroppedWithoutLostIsNoLongerLive() async throws {
        let sleeper = Sleeper()
        let changes = CloudMachineChanges(sleep: { try await sleeper.sleep($0) })
        changes.startPush({ _ in }) { _ in }
        var reads = 0
        changes.listed([CloudMachine(id: "kept"), CloudMachine(id: "dropped")]) { reads += 1 }
        changes.machineState(try Self.push(#"{"machine":"kept","kind":"live"}"#))
        changes.machineState(try Self.push(#"{"machine":"dropped","kind":"live"}"#))
        #expect(changes.isPushed("kept") && changes.isPushed("dropped"))
        // A list without the machine: the daemon closes its socket and sends no `lost`.
        changes.listed([CloudMachine(id: "kept")]) { reads += 1 }
        #expect(!changes.isPushed("dropped"))
        #expect(changes.isPushed("kept"))
        #expect(!changes.isSettling)
        // The daemon's connection closed: every socket of it is gone, again without a `lost`; reads come back.
        changes.daemonDisconnected()
        #expect(changes.live.isEmpty)
        #expect(changes.isSettling, "a machine whose push ended falls back to a read")
        #expect(await sleeper.next() == .seconds(3))
        sleeper.advance()
        _ = await sleeper.next()
        #expect(reads == 1)
        changes.stop()
        sleeper.advance()
    }
}
