import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohLANHostPublisherTests {
    @Test
    func verifiedRendezvousReplacementRemovesOldAlias() async throws {
        let service = RecordingBonjourPublisher()
        let binding = try hostBinding()
        let host = CmxIrohLANHostPublisher(
            publisher: service,
            interfaces: TestHostLANInterfaces(values: [try hostInterface()]),
            clock: FixedHostLANClock()
        )

        await host.activate(
            rendezvous: try rendezvous(generation: 1),
            binding: binding,
            directAddresses: { ["192.168.1.10:50906"] }
        )
        await host.activate(
            rendezvous: try rendezvous(generation: 2),
            binding: binding,
            directAddresses: { ["192.168.1.10:50906"] }
        )

        let replacements = await service.replacements()
        #expect(replacements.count == 2)
        let first = try #require(replacements[0].first)
        let second = try #require(replacements[1].first)
        #expect(first.alias != second.alias)
        #expect(!replacements[1].contains(where: { $0.alias == first.alias }))
        #expect(second.hostTarget == "h-\(second.alias).local.")
        await host.stop()
    }

    @Test
    func policyDenialDisablesOnlyBonjourPublisher() async throws {
        let service = RecordingBonjourPublisher(error: .policyDenied)
        let host = CmxIrohLANHostPublisher(
            publisher: service,
            interfaces: TestHostLANInterfaces(values: [try hostInterface()]),
            clock: FixedHostLANClock()
        )

        await host.activate(
            rendezvous: try rendezvous(generation: 1),
            binding: try hostBinding(),
            directAddresses: { ["192.168.1.10:50906"] }
        )

        #expect(await host.snapshot() == .policyDenied)
        #expect(await service.replacements().isEmpty)
        await host.stop()
    }

    @Test
    func activeListenerCanRetryAfterPermissionMayHaveChanged() async throws {
        let service = RecordingBonjourPublisher(error: .policyDenied)
        let host = CmxIrohLANHostPublisher(
            publisher: service,
            interfaces: TestHostLANInterfaces(values: [try hostInterface()]),
            clock: FixedHostLANClock()
        )
        await host.activate(
            rendezvous: try rendezvous(generation: 1),
            binding: try hostBinding(),
            directAddresses: { ["192.168.1.10:50906"] }
        )
        #expect(await host.snapshot() == .policyDenied)

        await service.allowPublishing()
        await host.permissionMayHaveChanged()

        #expect(await host.snapshot() == .active)
        #expect(await service.replacements().count == 1)
        await host.stop()
        await host.permissionMayHaveChanged()
        #expect(await service.replacements().count == 1)
    }

    private func hostInterface() throws -> CmxIrohLANInterfaceAddress {
        try CmxIrohLANInterfaceAddress(
            interfaceIndex: 4,
            ipAddress: "192.168.1.10",
            netmask: "255.255.255.0"
        )
    }

    private func hostBinding() throws -> CmxIrohBrokerBindingMetadata {
        try CmxIrohBrokerBindingMetadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174010",
            deviceID: "123e4567-e89b-42d3-a456-426614174011",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174012",
            tag: "test",
            platform: .mac,
            endpointID: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
            identityGeneration: 1
        )
    }

    private func rendezvous(generation: Int) throws -> CmxIrohLANRendezvous {
        let key = Data(repeating: 7, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try JSONDecoder().decode(
            CmxIrohLANRendezvous.self,
            from: JSONSerialization.data(withJSONObject: [
                "generation": generation,
                "key": key,
            ])
        )
    }
}

private struct TestHostLANInterfaces: CmxIrohLANInterfaceSnapshotProviding {
    let values: [CmxIrohLANInterfaceAddress]
    func interfaceAddresses() throws -> [CmxIrohLANInterfaceAddress] { values }
}

private struct FixedHostLANClock: CmxIrohLANClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_001) }
    func sleep(for _: TimeInterval) async throws {
        try await ContinuousClock().sleep(for: .seconds(600))
    }
}

private actor RecordingBonjourPublisher: CmxIrohBonjourPublishing {
    private var error: CmxIrohLANDiscoveryError?
    private var recorded: [[CmxIrohLANAdvertisement]] = []
    private var continuations: [AsyncStream<CmxIrohBonjourPublisherEvent>.Continuation] = []

    init(error: CmxIrohLANDiscoveryError? = nil) {
        self.error = error
    }

    func events() -> AsyncStream<CmxIrohBonjourPublisherEvent> {
        AsyncStream { continuations.append($0) }
    }

    func replace(with advertisements: [CmxIrohLANAdvertisement]) throws {
        if let error { throw error }
        recorded.append(advertisements)
    }

    func stop() {
        for continuation in continuations { continuation.finish() }
        continuations.removeAll()
    }

    func allowPublishing() { error = nil }

    func replacements() -> [[CmxIrohLANAdvertisement]] { recorded }
}
