import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Virtual-time tests for the two-phase pairing race: the credential-free
/// probe race picks one winning route, the credentialed finalize runs on that
/// single winner only, a route-local finalize failure falls back to the
/// remaining routes, and a route-independent finalize failure ends the whole
/// connect. Time only moves when the test advances the `ManualTestClock`.
@Suite struct MobilePairingTwoPhaseRaceTests {
    private func route(_ id: String, host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: 17_345)
        )
    }

    /// Records probe starts, finalize invocations, and discarded probes, so
    /// tests can assert exactly which endpoints saw the credentialed phase.
    private actor TwoPhaseRecorder {
        private(set) var probedRouteIDs: [String] = []
        private(set) var finalizedProbes: [String] = []
        private(set) var discardedProbes: [String] = []

        func recordProbe(_ id: String) { probedRouteIDs.append(id) }
        func recordFinalize(_ probe: String) { finalizedProbes.append(probe) }
        func recordDiscarded(_ probe: String) { discardedProbes.append(probe) }
    }

    /// Parks until the surrounding task is cancelled, then returns normally
    /// (a probe whose success completes only after it already lost).
    private func parkUntilCancelledThenReturn() async {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
    }

    /// The credentialed finalize must touch exactly one endpoint: the probe
    /// race's winner. Sibling routes are cancelled mid-probe and never see a
    /// finalize.
    @Test func finalizeRunsOnlyOnTheProbeWinner() async throws {
        let recorder = TwoPhaseRecorder()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let twoPhase = MobilePairingTwoPhaseRace(race: MobilePairingRouteRace(clock: ManualTestClock()))

        let win = try await twoPhase.run(
            routes: routes,
            endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
            probe: { route in
                await recorder.recordProbe(route.id)
                return "conn-\(route.id)"
            },
            onDiscardedProbe: { await recorder.recordDiscarded($0) },
            finalize: { route, probe in
                await recorder.recordFinalize(probe)
                return "win-\(route.id)"
            }
        )

        #expect(win == "win-a")
        #expect(await recorder.finalizedProbes == ["conn-a"])
        // Route b was still parked on its stagger sleep when a won, so it was
        // cancelled without ever probing, let alone receiving the credential.
        #expect(await recorder.probedRouteIDs == ["a"])
        #expect(await recorder.discardedProbes.isEmpty)
    }

    /// A probe success that lands after the winner was chosen is handed to the
    /// discard hook (its connection is torn down), and never finalized.
    @Test func lateProbeSuccessIsDiscardedAndNeverFinalized() async throws {
        let clock = ManualTestClock()
        let recorder = TwoPhaseRecorder()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let twoPhase = MobilePairingTwoPhaseRace(race: MobilePairingRouteRace(clock: clock))

        let raceTask = Task {
            try await twoPhase.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                probe: { route in
                    await recorder.recordProbe(route.id)
                    if route.id == "a" {
                        // Completes successfully, but only once the race has
                        // already cancelled it (its success arrives too late).
                        await self.parkUntilCancelledThenReturn()
                    }
                    return "conn-\(route.id)"
                },
                onDiscardedProbe: { await recorder.recordDiscarded($0) },
                finalize: { route, probe in
                    await recorder.recordFinalize(probe)
                    return "win-\(route.id)"
                }
            )
        }

        // Route a probes immediately and hangs; advancing past the stagger
        // releases route b, which wins.
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(250))

        let win = try await raceTask.value
        #expect(win == "win-b")
        #expect(await recorder.finalizedProbes == ["conn-b"])
        #expect(await recorder.discardedProbes == ["conn-a"])
    }

    /// A route-local finalize failure (the probe winner is the wrong Mac at a
    /// stale address and rejects the credential) discards that probe and
    /// re-runs the race over the remaining routes instead of failing pairing.
    @Test func routeLocalFinalizeFailureFallsBackToRemainingRoutes() async throws {
        let recorder = TwoPhaseRecorder()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let twoPhase = MobilePairingTwoPhaseRace(race: MobilePairingRouteRace(clock: ManualTestClock()))

        let win = try await twoPhase.run(
            routes: routes,
            endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
            probe: { route in
                await recorder.recordProbe(route.id)
                return "conn-\(route.id)"
            },
            onDiscardedProbe: { await recorder.recordDiscarded($0) },
            finalize: { route, probe in
                await recorder.recordFinalize(probe)
                if route.id == "a" {
                    throw MobileShellConnectionError.authorizationFailed("not your mac")
                }
                return "win-\(route.id)"
            }
        )

        #expect(win == "win-b")
        // Round 1 finalized a's probe and failed; round 2 finalized b's.
        #expect(await recorder.finalizedProbes == ["conn-a", "conn-b"])
        // The failed winner's connection was torn down through the discard hook.
        #expect(await recorder.discardedProbes == ["conn-a"])
        // The excluded route was not re-probed in round 2.
        #expect(await recorder.probedRouteIDs == ["a", "b"])
    }

    /// A route-independent finalize failure (the locally checked ticket
    /// expiry) must end the whole connect instead of burning the remaining
    /// routes on a ticket that is expired everywhere.
    @Test func routeIndependentFinalizeFailureEndsTheFallback() async throws {
        let recorder = TwoPhaseRecorder()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let twoPhase = MobilePairingTwoPhaseRace(race: MobilePairingRouteRace(clock: ManualTestClock()))

        do {
            _ = try await twoPhase.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                probe: { route in
                    await recorder.recordProbe(route.id)
                    return "conn-\(route.id)"
                },
                onDiscardedProbe: { await recorder.recordDiscarded($0) },
                finalize: { _, probe -> String in
                    await recorder.recordFinalize(probe)
                    throw MobileShellConnectionError.attachTicketExpired
                }
            )
            Issue.record("two-phase race should throw when finalize fails route-independently")
        } catch let failure as MobilePairingRouteRaceFailure {
            #expect(failure.raceEndingFailure?.route.id == "a")
            guard let representative = failure.representative?.error as? MobileShellConnectionError,
                  case .attachTicketExpired = representative else {
                Issue.record("representative should carry the ticket expiry")
                return
            }
        }
        // No second round: the expiry is identical on every route.
        #expect(await recorder.finalizedProbes == ["conn-a"])
        #expect(await recorder.discardedProbes == ["conn-a"])
    }

    /// When every route's finalize fails route-locally, the thrown failure
    /// carries each route's finalize failure in priority order, so the
    /// representative classification sees all of them.
    @Test func exhaustedFallbackCombinesFinalizeFailuresAcrossRounds() async throws {
        let recorder = TwoPhaseRecorder()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let twoPhase = MobilePairingTwoPhaseRace(race: MobilePairingRouteRace(clock: ManualTestClock()))

        do {
            _ = try await twoPhase.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                probe: { route in "conn-\(route.id)" },
                onDiscardedProbe: { await recorder.recordDiscarded($0) },
                finalize: { route, _ -> String in
                    throw MobileShellConnectionError.authorizationFailed("rejected by \(route.id)")
                }
            )
            Issue.record("two-phase race should throw when every route's finalize fails")
        } catch let failure as MobilePairingRouteRaceFailure {
            #expect(failure.raceEndingFailure == nil)
            #expect(failure.failures.map(\.route.id) == ["a", "b"])
            #expect(failure.failures.map(\.routeIndex) == [0, 1])
        }
        #expect(await recorder.discardedProbes == ["conn-a", "conn-b"])
    }

    /// A finalize failure followed by a fallback round whose probes all fail
    /// merges both phases' failures into one error, indexed against the
    /// original priority order.
    @Test func probeFailuresInFallbackRoundCombineWithEarlierFinalizeFailures() async throws {
        let recorder = TwoPhaseRecorder()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let twoPhase = MobilePairingTwoPhaseRace(race: MobilePairingRouteRace(clock: ManualTestClock()))

        do {
            _ = try await twoPhase.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                probe: { route in
                    if route.id == "b" {
                        throw CmxNetworkByteTransportError.connectionTimedOut
                    }
                    return "conn-\(route.id)"
                },
                onDiscardedProbe: { await recorder.recordDiscarded($0) },
                finalize: { _, _ -> String in
                    throw MobileShellConnectionError.authorizationFailed("not your mac")
                }
            )
            Issue.record("two-phase race should throw when the fallback round also fails")
        } catch let failure as MobilePairingRouteRaceFailure {
            #expect(failure.failures.map(\.route.id) == ["a", "b"])
            #expect(failure.failures.map(\.routeIndex) == [0, 1])
            // The auth rejection out-ranks the sibling's transport timeout.
            #expect(failure.representative?.route.id == "a")
        }
        #expect(await recorder.discardedProbes == ["conn-a"])
    }

    /// The caller cancelling the connect mid-finalize must surface as
    /// cancellation (silent in the pairing UI), not as a route failure that
    /// triggers another fallback round; the winner's probe is still torn down.
    @Test func callerCancellationDuringFinalizeSurfacesAsCancellation() async throws {
        let recorder = TwoPhaseRecorder()
        let routes = [try route("a", host: "100.64.0.1"), try route("b", host: "100.64.0.2")]
        let twoPhase = MobilePairingTwoPhaseRace(race: MobilePairingRouteRace(clock: ManualTestClock()))

        let started = AsyncStream<Void>.makeStream()
        let raceTask = Task {
            try await twoPhase.run(
                routes: routes,
                endsRace: { MobilePairingRouteAttempt.failureEndsRouteRace($0) },
                probe: { route in "conn-\(route.id)" },
                onDiscardedProbe: { await recorder.recordDiscarded($0) },
                finalize: { route, _ -> String in
                    started.continuation.yield()
                    await self.parkUntilCancelledThenReturn()
                    throw CancellationError()
                }
            )
        }

        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        raceTask.cancel()

        let result = await raceTask.result
        guard case let .failure(error) = result else {
            Issue.record("cancelled connect should propagate cancellation")
            return
        }
        #expect(error is CancellationError)
        #expect(await recorder.discardedProbes == ["conn-a"])
    }
}
