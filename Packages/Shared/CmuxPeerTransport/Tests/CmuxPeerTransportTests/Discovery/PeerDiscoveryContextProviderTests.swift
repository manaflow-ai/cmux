import CMUXMobileCore
import CmuxPeerTransportCore
import Foundation
import Testing

@testable import CmuxPeerTransport

private enum DiscoveryFixture {
    static let deviceA = "123e4567-e89b-42d3-a456-426614174001"
    static let deviceB = "123e4567-e89b-42d3-a456-426614174009"
    static let relayURL = "https://usw1.relay.cmux.dev/"

    static func binding(
        index: Int,
        deviceID: String,
        tag: String
    ) -> String {
        """
        {
          "binding_id": "\(String(format: "123e4567-e89b-42d3-a456-%012d", index))",
          "device_id": "\(deviceID)",
          "app_instance_id": "\(String(format: "223e4567-e89b-42d3-a456-%012d", index))",
          "tag": "\(tag)",
          "platform": "mac",
          "display_name": "Mac \(index)",
          "endpoint_id": "\(String(format: "%064x", index + 1))",
          "identity_generation": 1,
          "pairing_enabled": true,
          "capabilities": ["control"],
          "path_hints": [
            {
              "kind": "relay_url",
              "value": "\(relayURL)",
              "source": "native",
              "privacy_scope": "public_internet",
              "observed_at": "2026-07-10T00:00:00.000Z",
              "expires_at": "2026-07-10T01:00:00.000Z"
            },
            {
              "kind": "direct_address",
              "value": "52.10.20.\(10 + index):4242",
              "source": "native",
              "privacy_scope": "public_internet",
              "observed_at": "2026-07-10T00:00:00.000Z",
              "expires_at": "2026-07-10T01:00:00.000Z"
            }
          ],
          "last_seen_at": "2026-07-10T00:00:00.000Z"
        }
        """
    }

    static func snapshot(bindings: [String]) throws -> PeerBrokerDiscoverySnapshot {
        let json = """
            {
              "route_contract_version": 1,
              "bindings": [\(bindings.joined(separator: ","))],
              "relay_fleet": ["\(relayURL)"],
              "lan_rendezvous": {
                "generation": 1,
                "key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
              },
              "grant_verification_keys": {
                "version": 1,
                "current_kid": "current",
                "keys": []
              }
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(PeerBrokerWire.decodeISO8601)
        return try decoder.decode(
            PeerBrokerDiscoverySnapshot.self,
            from: Data(json.utf8)
        )
    }
}

private final class DiscoveryScript: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<PeerBrokerDiscoverySnapshot, any Error>]
    private(set) var callCount = 0

    init(_ results: [Result<PeerBrokerDiscoverySnapshot, any Error>]) {
        self.results = results
    }

    func next() throws -> PeerBrokerDiscoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        guard !results.isEmpty else {
            struct Exhausted: Error {}
            throw Exhausted()
        }
        let result = results.count == 1 ? results[0] : results.removeFirst()
        return try result.get()
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

private struct DiscoveryDown: Error {}

@Suite struct PeerDiscoveryContextProviderTests {
    private func provider(
        script: DiscoveryScript,
        reuseWindow: Duration = .seconds(30)
    ) -> PeerDiscoveryContextProvider {
        PeerDiscoveryContextProvider(reuseWindow: reuseWindow) {
            try script.next()
        }
    }

    @Test func freshDiscoveryProducesPlanWithSplitHints() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable")
        ])
        let script = DiscoveryScript([.success(snapshot)])
        let provider = provider(script: script)

        let plan = try await provider.dialPlan(
            macDeviceID: DiscoveryFixture.deviceA.uppercased(),
            tag: nil
        )
        #expect(plan.relayHints == [DiscoveryFixture.relayURL])
        #expect(plan.directHints == ["52.10.20.11:4242"])
        #expect(plan.fetchedFreshly)
    }

    @Test func reuseWindowAvoidsASecondBrokerFetch() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable")
        ])
        let script = DiscoveryScript([.success(snapshot)])
        let provider = provider(script: script)

        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        let second = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        #expect(script.calls == 1)
        #expect(!second.fetchedFreshly)
    }

    @Test func unreachableFailureMarksStaleAndBypassesReuseOnce() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable")
        ])
        let script = DiscoveryScript([.success(snapshot)])
        let provider = provider(script: script)

        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        await provider.noteDialFailure(
            macDeviceID: DiscoveryFixture.deviceA,
            classification: .unreachable,
            planWasEmpty: false
        )
        let plan = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        #expect(script.calls == 2)
        #expect(plan.fetchedFreshly)
    }

    @Test func authorizationFailureDoesNotTriggerRefetch() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable")
        ])
        let script = DiscoveryScript([.success(snapshot)])
        let provider = provider(script: script)

        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        await provider.noteDialFailure(
            macDeviceID: DiscoveryFixture.deviceA,
            classification: .authorizationDenied,
            planWasEmpty: false
        )
        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        #expect(script.calls == 1)
    }

    @Test func presenceInvalidationForcesFreshDiscovery() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable")
        ])
        let script = DiscoveryScript([.success(snapshot)])
        let provider = provider(script: script)

        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        await provider.invalidate(macDeviceID: DiscoveryFixture.deviceA)
        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        #expect(script.calls == 2)
    }

    @Test func concurrentDialsShareOneInFlightFetch() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable")
        ])
        let script = DiscoveryScript([.success(snapshot)])
        let provider = provider(script: script)

        async let a = provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        async let b = provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        async let c = provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        _ = try await (a, b, c)
        #expect(script.calls == 1)
    }

    @Test func discoveryFailureKeepsPriorContextAlive() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable")
        ])
        let script = DiscoveryScript([.success(snapshot), .failure(DiscoveryDown())])
        let provider = provider(script: script, reuseWindow: .zero)

        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        // Window elapsed; refetch fails; prior context still yields a plan.
        let plan = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        #expect(!plan.fetchedFreshly)
    }

    @Test func discoveryFailureWithNoPriorContextThrowsUnavailable() async {
        let script = DiscoveryScript([.failure(DiscoveryDown())])
        let provider = provider(script: script)

        do {
            _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
            Issue.record("expected discoveryUnavailable")
        } catch let error as PeerDiscoveryContextError {
            #expect(error.kind == .discoveryUnavailable)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func taglessLookupMatchingTwoSiblingBuildsFailsClosed() async throws {
        let snapshot = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable"),
            DiscoveryFixture.binding(index: 2, deviceID: DiscoveryFixture.deviceA, tag: "nightly"),
        ])
        let script = DiscoveryScript([.success(snapshot)])
        let provider = provider(script: script)

        await #expect(throws: PeerDiscoveryContextError.self) {
            _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        }
        let tagged = try await provider.dialPlan(
            macDeviceID: DiscoveryFixture.deviceA,
            tag: "nightly"
        )
        #expect(tagged.binding.tag == "nightly")
    }

    @Test func emptyReusedPlanRebuildsOnceFromFreshDiscovery() async throws {
        let empty = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 5, deviceID: DiscoveryFixture.deviceB, tag: "stable")
        ])
        let withTarget = try DiscoveryFixture.snapshot(bindings: [
            DiscoveryFixture.binding(index: 1, deviceID: DiscoveryFixture.deviceA, tag: "stable"),
            DiscoveryFixture.binding(index: 5, deviceID: DiscoveryFixture.deviceB, tag: "stable"),
        ])
        let script = DiscoveryScript([.success(empty), .success(withTarget)])
        let provider = provider(script: script)

        // Warm the snapshot with a different device's plan.
        _ = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceB, tag: nil)
        // Reused snapshot lacks device A: rebuilds once, fresh result wins.
        let plan = try await provider.dialPlan(macDeviceID: DiscoveryFixture.deviceA, tag: nil)
        #expect(plan.fetchedFreshly)
        #expect(script.calls == 2)
    }
}
