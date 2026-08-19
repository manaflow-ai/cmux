import CmuxPeerTransportCore
import Foundation
import Testing

@testable import CmuxPeerTransport

@Suite struct PeerRelayRotationPlannerTests {
    private struct ConfigFactory {
        let now = Date(timeIntervalSince1970: 1_782_000_000)

        func config(url: String, token: String) throws -> PeerRelayConfig {
            try PeerRelayConfig(
                url: url,
                authToken: token,
                expiresAt: now.addingTimeInterval(300),
                refreshAfter: now.addingTimeInterval(240),
                now: now
            )
        }
    }

    private let usURL = "https://usc1.relay.cmux.dev/"
    private let euURL = "https://euw4.relay.cmux.dev/"
    private let apURL = "https://apne1.relay.cmux.dev/"

    @Test func rotationInsertsRefreshedAwaitsHealthThenRemovesStale() throws {
        let factory = ConfigFactory()
        let oldUS = try factory.config(url: usURL, token: "old.us.token")
        let oldEU = try factory.config(url: euURL, token: "old.eu.token")
        let newUS = try factory.config(url: usURL, token: "new.us.token")
        let newAP = try factory.config(url: apURL, token: "new.ap.token")
        let generation = PeerTransportGeneration(rawValue: 3)

        let plan = PeerRelayRotationPlanner().plan(
            applied: [oldUS, oldEU],
            refreshed: [newUS, newAP],
            generation: generation
        )

        #expect(plan.steps == [
            .insertRelay(newUS),
            .insertRelay(newAP),
            .awaitHomeRelayHealthy,
            .removeRelay(url: euURL),
        ])
        #expect(!plan.isNoOp)
    }

    @Test func sameFleetTokenRefreshHasNoRemovals() throws {
        let factory = ConfigFactory()
        let oldUS = try factory.config(url: usURL, token: "old.us.token")
        let oldEU = try factory.config(url: euURL, token: "old.eu.token")
        let newUS = try factory.config(url: usURL, token: "new.us.token")
        let newEU = try factory.config(url: euURL, token: "new.eu.token")

        let plan = PeerRelayRotationPlanner().plan(
            applied: [oldUS, oldEU],
            refreshed: [newUS, newEU],
            generation: .initial
        )

        #expect(plan.steps == [
            .insertRelay(newUS),
            .insertRelay(newEU),
            .awaitHomeRelayHealthy,
        ])
        #expect(plan.rollback == [
            .insertRelay(oldUS),
            .insertRelay(oldEU),
        ])
    }

    @Test func identicalAppliedAndRefreshedSetsPlanNoOp() throws {
        let factory = ConfigFactory()
        let us = try factory.config(url: usURL, token: "same.us.token")
        let eu = try factory.config(url: euURL, token: "same.eu.token")

        let plan = PeerRelayRotationPlanner().plan(
            applied: [us, eu],
            refreshed: [eu, us],
            generation: .initial
        )

        #expect(plan.isNoOp)
        #expect(plan.steps.isEmpty)
        #expect(plan.rollback.isEmpty)
    }

    @Test func initialApplicationFromEmptyAppliedSet() throws {
        let factory = ConfigFactory()
        let us = try factory.config(url: usURL, token: "new.us.token")
        let eu = try factory.config(url: euURL, token: "new.eu.token")

        let plan = PeerRelayRotationPlanner().plan(
            applied: [],
            refreshed: [us, eu],
            generation: .initial
        )

        #expect(plan.steps == [
            .insertRelay(us),
            .insertRelay(eu),
            .awaitHomeRelayHealthy,
        ])
        #expect(plan.rollback == [
            .removeRelay(url: usURL),
            .removeRelay(url: euURL),
        ])
    }

    @Test func emptyRefreshedSetPlansFailClosedRemoval() throws {
        let factory = ConfigFactory()
        let us = try factory.config(url: usURL, token: "old.us.token")
        let eu = try factory.config(url: euURL, token: "old.eu.token")

        let plan = PeerRelayRotationPlanner().plan(
            applied: [us, eu],
            refreshed: [],
            generation: .initial
        )

        // Rotating to zero relays (fail-closed direct-only) never awaits
        // home-relay health on a set that cannot become healthy.
        #expect(plan.steps == [
            .removeRelay(url: usURL),
            .removeRelay(url: euURL),
        ])
        #expect(plan.rollback == [
            .insertRelay(us),
            .insertRelay(eu),
        ])
    }

    @Test func rollbackRestoresPriorSetAfterForwardFailure() throws {
        let factory = ConfigFactory()
        let oldUS = try factory.config(url: usURL, token: "old.us.token")
        let oldEU = try factory.config(url: euURL, token: "old.eu.token")
        let newUS = try factory.config(url: usURL, token: "new.us.token")
        let newAP = try factory.config(url: apURL, token: "new.ap.token")
        let generation = PeerTransportGeneration(rawValue: 5)

        let plan = PeerRelayRotationPlanner().plan(
            applied: [oldUS, oldEU],
            refreshed: [newUS, newAP],
            generation: generation
        )

        // Prior tokens are re-inserted (a same-URL insert restores the stale
        // entry) and refreshed-only URLs are removed.
        #expect(plan.rollbackSteps(ifCurrent: generation) == [
            .insertRelay(oldUS),
            .insertRelay(oldEU),
            .removeRelay(url: apURL),
        ])
    }

    @Test func generationGuardRejectsStalePlanAndRollback() throws {
        let factory = ConfigFactory()
        let old = try factory.config(url: usURL, token: "old.us.token")
        let new = try factory.config(url: usURL, token: "new.us.token")
        let planned = PeerTransportGeneration(rawValue: 2)

        let plan = PeerRelayRotationPlanner().plan(
            applied: [old],
            refreshed: [new],
            generation: planned
        )

        #expect(plan.steps(ifCurrent: planned) != nil)
        #expect(plan.rollbackSteps(ifCurrent: planned) != nil)

        let recreated = planned.next()
        #expect(plan.steps(ifCurrent: recreated) == nil)
        #expect(plan.rollbackSteps(ifCurrent: recreated) == nil)
    }
}
