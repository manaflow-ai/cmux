import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Virtual-time tests for the Happy-Eyeballs pairing route race: attempts
/// start with a priority stagger, the first success wins, losers are cancelled
/// (and a too-late success is discarded, not leaked), a definitive host answer
/// ends the race early, and the all-failed error surfaces the most actionable
/// route failure. Time only moves when the test advances the `ManualTestClock`,
/// so none of these wait in real time.
@Suite struct MobilePairingRouteRaceTests {
    private func route(_ id: String, host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: 17_345)
        )
    }

    /// Records attempt starts (with their virtual-clock offsets), observed
    /// cancellations, and discarded successes, with a waiter so tests advance
    /// the clock only after the expected attempts are actually running.
    private actor RaceProbe {
        private(set) var startedRouteIDs: [String] = []
        private(set) var startOffsets: [String: Duration] = [:]
        private(set) var cancelledRouteIDs: [String] = []
        private(set) var discardedValues: [String] = []
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func recordStart(_ id: String, at offset: Duration) {
            startedRouteIDs.append(id)
            startOffsets[id] = offset
            let reached = startedRouteIDs.count
            let satisfied = startWaiters.filter { reached >= $0.count }
            startWaiters.removeAll { reached >= $0.count }
            for waiter in satisfied { waiter.continuation.resume() }
        }

        func recordCancelled(_ id: String) { cancelledRouteIDs.append(id) }
        func recordDiscarded(_ value: String) { discardedValues.append(value) }

        func waitForStarts(_ count: Int) async {
            if startedRouteIDs.count >= count { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }
    }

    /// Parks until the surrounding task is cancelled, then throws
    /// `CancellationError` (a cancellation-responsive hung attempt).
    private func parkUntilCancelled() async throws {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
        throw CancellationError()
    }

    /// Parks until the surrounding task is cancelled, then returns normally
    /// (an attempt whose success completes only after it already lost).
    private func parkUntilCancelledThenReturn() async {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
    }

    @Test func firstSuccessWinsAndHungLoserIsCancelled() async throws {
        let clock = ManualTestClock()
        let probe = RaceProbe()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let race = MobilePairingRouteRace(clock: clock)

        let raceTask = Task {
            try await race.run(
                routes: routes,
                endsRace: { _ in false },
                onDiscardedSuccess: { await probe.recordDiscarded($0) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    if route.id == "a" {
                        do {
                            try await self.parkUntilCancelled()
                        } catch {
                            await probe.recordCancelled(route.id)
                            throw error
                        }
                    }
                    return route.id
                }
            )
        }

        // Route a starts immediately and hangs; route b is still parked on its
        // stagger sleep until the clock advances.
        await probe.waitForStarts(1)
        #expect(await probe.startedRouteIDs == ["a"])
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(250))

        let winner = try await raceTask.value
        #expect(winner == "b")
        // The hung route a must have been cancelled and joined, not left running.
        #expect(await probe.cancelledRouteIDs == ["a"])
        #expect(await probe.discardedValues.isEmpty)
    }

    @Test func attemptsStartInPriorityOrderWithStagger() async throws {
        let clock = ManualTestClock()
        let probe = RaceProbe()
        let routes = [
            try route("a", host: "100.64.0.1"),
            try route("b", host: "100.64.0.2"),
            try route("c", host: "100.64.0.3"),
        ]
        let race = MobilePairingRouteRace(clock: clock)

        let raceTask = Task {
            try await race.run(
                routes: routes,
                endsRace: { _ in false },
                onDiscardedSuccess: { await probe.recordDiscarded($0) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    try await self.parkUntilCancelled()
                    return route.id
                }
            )
        }

        // Route a starts with no delay; b and c park on their stagger sleeps.
        await probe.waitForStarts(1)
        await clock.waitUntilSleepers(count: 2)
        clock.advance(by: .milliseconds(250))
        await probe.waitForStarts(2)
        clock.advance(by: .milliseconds(250))
        await probe.waitForStarts(3)

        let offsets = await probe.startOffsets
        #expect(await probe.startedRouteIDs == ["a", "b", "c"])
        #expect(offsets["a"] == .zero)
        #expect(offsets["b"] == .milliseconds(250))
        #expect(offsets["c"] == .milliseconds(500))

        // External cancellation while every attempt hangs surfaces as
        // CancellationError (silent in the pairing UI), not all-routes-failed.
        raceTask.cancel()
        let result = await raceTask.result
        guard case let .failure(error) = result else {
            Issue.record("race should propagate external cancellation")
            return
        }
        #expect(error is CancellationError)
    }

    @Test func lateSuccessAfterWinnerIsDiscardedNotLeaked() async throws {
        let clock = ManualTestClock()
        let probe = RaceProbe()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let race = MobilePairingRouteRace(clock: clock)

        let raceTask = Task {
            try await race.run(
                routes: routes,
                endsRace: { _ in false },
                onDiscardedSuccess: { await probe.recordDiscarded($0) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    if route.id == "a" {
                        // Completes successfully, but only once the race has
                        // already cancelled it (its success arrives too late).
                        await self.parkUntilCancelledThenReturn()
                    }
                    return route.id
                }
            )
        }

        await probe.waitForStarts(1)
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(250))

        let winner = try await raceTask.value
        #expect(winner == "b")
        // Route a's late success must be handed to the discard hook so its
        // connection is torn down instead of leaking.
        #expect(await probe.discardedValues == ["a"])
    }

    @Test func raceEndingFailureStopsSiblingsBeforeTheyStart() async throws {
        let clock = ManualTestClock()
        let probe = RaceProbe()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let race = MobilePairingRouteRace(clock: clock)
        let hostAnswer = MobileShellConnectionError.rpcError("account_mismatch", "different account")

        do {
            _ = try await race.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                onDiscardedSuccess: { (value: String) in await probe.recordDiscarded(value) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    throw hostAnswer
                }
            )
            Issue.record("race should throw when the host answer ends it")
        } catch let failure as MobilePairingRouteRaceFailure {
            // The host's definitive answer is the representative failure, and
            // route b was cancelled out of its stagger sleep without ever
            // dialing: no clock advance was needed to resolve the race.
            #expect(failure.raceEndingFailure?.route.id == "a")
            #expect(failure.representative?.route.id == "a")
            guard let representativeError = failure.representative?.error as? MobileShellConnectionError,
                  case .rpcError = representativeError else {
                Issue.record("representative should carry the host's RPC answer")
                return
            }
        }
        #expect(await probe.startedRouteIDs == ["a"])
    }

    @Test func successCompletingAfterRaceEndingFailureStillWins() async throws {
        let clock = ManualTestClock()
        let probe = RaceProbe()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let race = MobilePairingRouteRace(clock: clock)

        let raceTask = Task {
            try await race.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                onDiscardedSuccess: { await probe.recordDiscarded($0) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    if route.id == "a" {
                        // The one-time-ticket race: this attempt consumed the
                        // ticket and connects, but its success only completes
                        // after route b's "already used" rejection has ended
                        // the race and cancelled it.
                        await self.parkUntilCancelledThenReturn()
                    } else {
                        throw MobileShellConnectionError.attachTicketExpired
                    }
                    return route.id
                }
            )
        }

        // Route a starts and parks; advancing past the stagger starts route b,
        // whose definitive host answer ends the race and cancels route a, which
        // then completes successfully anyway.
        await probe.waitForStarts(1)
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(250))

        // The live connection must win; the race-ending failure stops waiting,
        // it does not override an established connection.
        let winner = try await raceTask.value
        #expect(winner == "a")
        #expect(await probe.discardedValues.isEmpty)
    }

    @Test func allFailedSurfacesMostActionableRouteFailure() async throws {
        let clock = ManualTestClock()
        let probe = RaceProbe()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let race = MobilePairingRouteRace(clock: clock)

        let raceTask = Task {
            try await race.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                onDiscardedSuccess: { (value: String) in await probe.recordDiscarded(value) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    if route.id == "a" {
                        // Low-signal bare timeout on the priority route.
                        throw CmxNetworkByteTransportError.connectionTimedOut
                    }
                    // Definitive reachability diagnosis on the secondary route.
                    throw CmxNetworkByteTransportError.connectionFailed("refused", .connectionRefused)
                }
            )
        }

        await probe.waitForStarts(1)
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(250))

        let result = await raceTask.result
        guard case let .failure(error) = result,
              let failure = error as? MobilePairingRouteRaceFailure else {
            Issue.record("race should throw MobilePairingRouteRaceFailure when every route fails")
            return
        }
        #expect(failure.failures.count == 2)
        // "Nothing is listening" (connection refused) is more actionable than
        // route a's bare timeout, so it wins representation despite priority.
        #expect(failure.representative?.route.id == "b")
        let category = MobilePairingFailureCategory.classify(
            error: failure.representative!.error,
            route: failure.representative!.route
        )
        #expect(category == .listenerNotRunning(host: "100.64.0.2", port: 17_345))
    }

    @Test func emptyRouteListFailsImmediately() async {
        let race = MobilePairingRouteRace(clock: ManualTestClock())
        do {
            _ = try await race.run(
                routes: [],
                endsRace: { _ in false },
                onDiscardedSuccess: { (_: String) in },
                attempt: { $0.id }
            )
            Issue.record("empty route list should throw")
        } catch let failure as MobilePairingRouteRaceFailure {
            #expect(failure.failures.isEmpty)
            #expect(failure.representative == nil)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Attempt predicates

    @Test func hostLevelAnswersEndTheRaceButRouteLocalFailuresDoNot() {
        #expect(MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.authorizationFailed("no")
        ))
        #expect(MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.accountMismatch("other account")
        ))
        #expect(MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.attachTicketExpired
        ))
        #expect(MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.rpcError("internal", "boom")
        ))
        // Route-local: a sibling route may still reach the host or be trusted.
        #expect(!MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.requestTimedOut
        ))
        #expect(!MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.insecureManualRoute
        ))
        #expect(!MobilePairingRouteAttempt.failureEndsRouteRace(
            CmxNetworkByteTransportError.connectionFailed("refused", .connectionRefused)
        ))
        #expect(!MobilePairingRouteAttempt.failureEndsRouteRace(CancellationError()))
    }

    @Test func deadPipeFailuresSkipTheFallbackRequestShape() {
        // A host-level answer means the pipe works: try the next request shape.
        #expect(MobilePairingRouteAttempt.shouldTryNextRequest(
            after: MobileShellConnectionError.rpcError("unauthorized", "no")
        ))
        #expect(MobilePairingRouteAttempt.shouldTryNextRequest(
            after: MobileShellConnectionError.invalidResponse
        ))
        // A dead or unresponsive pipe would only stack a second timeout.
        #expect(!MobilePairingRouteAttempt.shouldTryNextRequest(
            after: MobileShellConnectionError.requestTimedOut
        ))
        #expect(!MobilePairingRouteAttempt.shouldTryNextRequest(
            after: MobileShellConnectionError.connectionClosed
        ))
        #expect(!MobilePairingRouteAttempt.shouldTryNextRequest(
            after: CmxNetworkByteTransportError.connectionTimedOut
        ))
        #expect(!MobilePairingRouteAttempt.shouldTryNextRequest(after: CancellationError()))
    }
}
