import Foundation
import Testing

import CmuxPeerTransportCore

@testable import CmuxPeerTransport

@Suite("PeerEndpointManager", .serialized)
struct PeerEndpointManagerTests {
    @Test(.timeLimit(.minutes(1)))
    func activatePublishesReadinessAndIdentity() async throws {
        let manager = PeerEndpointManager()
        #expect(await manager.endpointID == nil)
        #expect(await manager.probeHealth() == .inactive)

        let generation = try await manager.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        // The barrier reports the same generation the activation returned.
        let barrierGeneration = try await manager.readiness.awaitActive(
            timeout: .seconds(5)
        )
        #expect(barrierGeneration == generation)
        #expect(manager.isCurrent(generation))
        #expect(await manager.probeHealth() == .healthy)

        let id = await manager.endpointID
        #expect(id?.count == 64)
        #expect(await manager.boundSocketAddresses().isEmpty == false)
        // Direct-only, no relay: home relay status must be disconnected.
        #expect(await manager.homeRelayStatus().isConnected == false)

        await manager.deactivate()
        #expect(await manager.endpointID == nil)
        #expect(await manager.probeHealth() == .inactive)
        #expect(!manager.isCurrent(generation))
    }

    @Test(.timeLimit(.minutes(1)))
    func recreatePreservesEndpointIDAndAdvancesGeneration() async throws {
        let manager = PeerEndpointManager()
        let secret = EndpointTestSupport.randomSecret()
        let firstGeneration = try await manager.activate(
            secretKey: secret, relays: [], directOnly: true
        )
        let firstID = await manager.endpointID
        #expect(firstID != nil)

        let secondGeneration = try await manager.recreate()
        let secondID = await manager.endpointID

        // Same secret: identity is stable. Runtime generation advances, and
        // the old generation is fenced out.
        #expect(secondID == firstID)
        #expect(secondGeneration > firstGeneration)
        #expect(manager.isCurrent(secondGeneration))
        #expect(!manager.isCurrent(firstGeneration))
        #expect(await manager.probeHealth() == .healthy)

        await manager.deactivate()
    }

    @Test func activateRejectsShortSecret() async throws {
        let manager = PeerEndpointManager()
        await #expect(throws: PeerEndpointManagerError.invalidSecretKey) {
            try await manager.activate(
                secretKey: Data([1, 2, 3]), relays: [], directOnly: true
            )
        }
    }

    @Test func recreateBeforeActivateThrows() async throws {
        let manager = PeerEndpointManager()
        await #expect(throws: PeerEndpointManagerError.notActivated) {
            try await manager.recreate()
        }
    }

    @Test func applyRelaysBeforeActivateThrows() async throws {
        let manager = PeerEndpointManager()
        await #expect(throws: PeerEndpointManagerError.notActivated) {
            try await manager.applyRelays(
                insert: [PeerRelayEndpointConfig(url: "https://relay.example.org/")],
                remove: []
            )
        }
    }

    @Test func awaitActiveTimesOutWhileInactive() async throws {
        let manager = PeerEndpointManager()
        await #expect(throws: PeerEndpointReadiness.TimedOut.self) {
            _ = try await manager.readiness.awaitActive(timeout: .milliseconds(80))
        }
    }
}
