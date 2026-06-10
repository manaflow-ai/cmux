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
        // The locally checked ticket expiry is the only failure that is
        // route-independent by construction (no host is consulted).
        let localExpiry = MobileShellConnectionError.attachTicketExpired

        do {
            _ = try await race.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                onDiscardedSuccess: { (value: String) in await probe.recordDiscarded(value) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    throw localExpiry
                }
            )
            Issue.record("race should throw when a local expiry check ends it")
        } catch let failure as MobilePairingRouteRaceFailure {
            // The route-independent expiry is the representative failure,
            // and route b was cancelled out of its stagger sleep without ever
            // dialing: no clock advance was needed to resolve the race.
            #expect(failure.raceEndingFailure?.route.id == "a")
            #expect(failure.representative?.route.id == "a")
            guard let representativeError = failure.representative?.error as? MobileShellConnectionError,
                  case .attachTicketExpired = representativeError else {
                Issue.record("representative should carry the local expiry")
                return
            }
        }
        #expect(await probe.startedRouteIDs == ["a"])
    }

    // An auth rejection is a HOST answer, and the answering endpoint is an
    // unverified candidate: a stale or reassigned address can host a different
    // Mac that rejects a ticket it never minted. The rejection must therefore
    // stay route-local; here the sibling route reaches the right Mac after the
    // stagger and its success must win instead of being cancelled.
    @Test func authRejectionOnOneRouteDoesNotCancelASiblingThatSucceeds() async throws {
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
                        // The wrong Mac at a stale address answers instantly
                        // with a protocol-valid rejection.
                        throw MobileShellConnectionError.authorizationFailed("not your mac")
                    }
                    return route.id
                }
            )
        }

        // Route a starts immediately and is rejected; route b must still be
        // started out of its stagger sleep rather than cancelled.
        await probe.waitForStarts(1)
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(250))

        let winner = try await raceTask.value
        #expect(winner == "b")
        #expect(await probe.startedRouteIDs == ["a", "b"])
        #expect(await probe.discardedValues.isEmpty)
    }

    @Test func routeFanOutIsCappedForUntrustedTickets() async throws {
        let clock = ManualTestClock()
        let probe = RaceProbe()
        // A crafted attach URL can carry an arbitrary route list; only the
        // first `maxRoutes` (default 8) may ever dial.
        let routes = try (0..<12).map { try route("r\($0)", host: "100.64.0.\($0 + 1)") }
        let race = MobilePairingRouteRace(clock: clock)

        let raceTask = Task {
            try await race.run(
                routes: routes,
                endsRace: { _ in false },
                onDiscardedSuccess: { (value: String) in await probe.recordDiscarded(value) },
                attempt: { route in
                    await probe.recordStart(route.id, at: clock.now.offset)
                    throw CmxNetworkByteTransportError.connectionTimedOut
                }
            )
        }

        // Route 0 starts immediately and fails; the other raced routes park on
        // their stagger sleeps. Advancing far past every stagger releases all
        // of them; routes beyond the cap were never spawned at all.
        await probe.waitForStarts(1)
        await clock.waitUntilSleepers(count: 7)
        clock.advance(by: .seconds(10))

        let result = await raceTask.result
        guard case let .failure(error) = result,
              let failure = error as? MobilePairingRouteRaceFailure else {
            Issue.record("race should throw MobilePairingRouteRaceFailure when every route fails")
            return
        }
        #expect(failure.failures.count == 8)
        #expect(await probe.startedRouteIDs.count == 8)
        #expect(await probe.startedRouteIDs.allSatisfy { id in
            routes.prefix(8).map(\.id).contains(id)
        })
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

    // A stale or reassigned address can host a different Mac that answers a
    // fast, protocol-valid auth rejection for a ticket it never minted, while
    // the route to the right Mac times out. Mixed evidence must surface the
    // reachability diagnosis (retry-able), not route the user into re-auth on
    // an unverified endpoint's rejection.
    @Test func mixedAuthRejectionAndTimeoutRepresentsReachabilityNotReauth() async throws {
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
                        // The wrong Mac at a stale address answers instantly.
                        throw MobileShellConnectionError.authorizationFailed("not your mac")
                    }
                    // The right Mac's address never answers.
                    throw CmxNetworkByteTransportError.connectionTimedOut
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
        #expect(failure.representative?.route.id == "b")
    }

    // When every route answers with an auth-style rejection, the rejection is
    // unanimous and definitive, and it must represent (single-route manual
    // pairing is the trivially unanimous case).
    @Test func unanimousAuthRejectionsStillRepresent() async throws {
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
                    throw MobileShellConnectionError.authorizationFailed("rejected by \(route.id)")
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
        #expect(failure.representative?.route.id == "a")
        let category = MobilePairingFailureCategory.classify(
            error: failure.representative!.error,
            route: failure.representative!.route
        )
        guard case .authFailed = category else {
            Issue.record("unanimous auth rejections should classify as authFailed")
            return
        }
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

    @Test func routeIndependentFailuresEndTheRaceButRouteLocalFailuresDoNot() {
        // Only the locally checked expiry is route-independent by construction.
        #expect(MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.attachTicketExpired
        ))
        // Route-local: the routes are unverified candidate endpoints, so ANY
        // host answer on one route (a stale or reassigned address hosting the
        // wrong Mac, the wrong service, an older host) must not stop a sibling
        // route from connecting. That includes auth rejections: the wrong Mac
        // rejects a ticket it never minted.
        #expect(!MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.authorizationFailed("no")
        ))
        #expect(!MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.accountMismatch("other account")
        ))
        #expect(!MobilePairingRouteAttempt.failureEndsRouteRace(
            MobileShellConnectionError.rpcError("internal", "boom")
        ))
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
