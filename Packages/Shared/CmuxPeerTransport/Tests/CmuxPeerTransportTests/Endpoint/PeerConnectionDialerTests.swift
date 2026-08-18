import Foundation
import Testing

import CmuxPeerTransportCore

@testable import CmuxPeerTransport

@Suite("PeerConnectionDialer", .serialized)
struct PeerConnectionDialerTests {
    @Test(.timeLimit(.minutes(1)))
    func dialUnreachableClassifiesWithoutCrash() async throws {
        let targetID = try await EndpointTestSupport.unreachableEndpointID()

        let manager = PeerEndpointManager()
        let generation = try await manager.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        let dialer = PeerConnectionDialer(manager: manager)
        do {
            _ = try await dialer.dial(
                endpointID: targetID,
                directHints: ["127.0.0.1:9"], // discard port: nothing answers
                generation: generation,
                timeout: .milliseconds(900)
            )
            Issue.record("dial to a dead endpoint unexpectedly succeeded")
        } catch let failure as PeerDialFailure {
            #expect(failure.classification == .unreachable)
        }
        await manager.deactivate()
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedEndpointIDClassifiesUnreachable() async throws {
        let manager = PeerEndpointManager()
        let generation = try await manager.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        let dialer = PeerConnectionDialer(manager: manager)
        do {
            _ = try await dialer.dial(
                endpointID: "not-an-endpoint-id",
                directHints: ["127.0.0.1:9"],
                generation: generation,
                timeout: .milliseconds(500)
            )
            Issue.record("malformed endpoint id unexpectedly dialed")
        } catch let failure as PeerDialFailure {
            #expect(failure.classification == .unreachable)
            #expect(failure.reason.contains("invalid endpoint id"))
        }
        await manager.deactivate()
    }

    @Test(.timeLimit(.minutes(1)))
    func dialWaitsForActivationBarrier() async throws {
        let targetID = try await EndpointTestSupport.unreachableEndpointID()

        let manager = PeerEndpointManager()
        let dialer = PeerConnectionDialer(manager: manager)
        let clock = ContinuousClock()
        let dialFinished = TestOrderingFlag()

        // Dial BEFORE activation: it must park on the barrier, not fail with
        // "endpoint unavailable".
        let dialTask = Task { () -> PeerDialFailure? in
            var result: PeerDialFailure?
            do {
                _ = try await dialer.dial(
                    endpointID: targetID,
                    directHints: ["127.0.0.1:9"],
                    timeout: .milliseconds(700),
                    readinessTimeout: .seconds(20)
                )
            } catch let failure as PeerDialFailure {
                result = failure
            } catch {
                result = nil
            }
            await dialFinished.set()
            return result
        }

        try await clock.sleep(for: .milliseconds(300))
        #expect(await dialFinished.isSet == false, "dial must park until activation")

        let activatedAt = clock.now
        _ = try await manager.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )

        let failure = await dialTask.value
        // The dial proceeded (and failed unreachable, since the target is
        // dead) strictly after activation.
        #expect(failure?.classification == .unreachable)
        let finishedAt = await dialFinished.setAt
        #expect(finishedAt != nil && finishedAt! >= activatedAt)
        await manager.deactivate()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationIsNeverConvertedToDialFailure() async throws {
        let targetID = try await EndpointTestSupport.unreachableEndpointID()

        let manager = PeerEndpointManager()
        let generation = try await manager.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        let dialer = PeerConnectionDialer(manager: manager)
        let dialTask = Task { () -> (any Error)? in
            do {
                _ = try await dialer.dial(
                    endpointID: targetID,
                    directHints: ["127.0.0.1:9"],
                    generation: generation,
                    timeout: .seconds(30) // long: cancellation must win
                )
                return nil
            } catch {
                return error
            }
        }
        try await ContinuousClock().sleep(for: .milliseconds(200))
        dialTask.cancel()
        let error = await dialTask.value
        #expect(error is CancellationError, "got \(String(describing: error))")
        await manager.deactivate()
    }

    @Test(.timeLimit(.minutes(1)))
    func staleGenerationFailsTransient() async throws {
        let manager = PeerEndpointManager()
        let firstGeneration = try await manager.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        _ = try await manager.recreate() // firstGeneration is now stale
        let dialer = PeerConnectionDialer(manager: manager)
        do {
            _ = try await dialer.dial(
                endpointID: try await EndpointTestSupport.unreachableEndpointID(),
                directHints: ["127.0.0.1:9"],
                generation: firstGeneration,
                timeout: .milliseconds(500)
            )
            Issue.record("stale-generation dial unexpectedly proceeded")
        } catch let failure as PeerDialFailure {
            #expect(failure.classification == .transient)
            #expect(failure.reason.contains("superseded"))
        }
        await manager.deactivate()
    }
}
