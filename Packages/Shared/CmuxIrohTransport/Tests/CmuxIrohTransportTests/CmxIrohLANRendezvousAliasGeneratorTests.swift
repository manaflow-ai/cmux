import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohLANRendezvousAliasGeneratorTests {
    @Test
    func aliasIsStableInsideEpochAndRotatesWithoutExposingTuple() throws {
        let generator = try makeGenerator(keyByte: 7, generation: 3)
        let binding = try makeBinding()
        let start = Date(timeIntervalSince1970: 1_800_000_001)

        let first = try generator.alias(for: binding, at: start)
        let sameEpoch = try generator.alias(
            for: binding,
            at: start.addingTimeInterval(120)
        )
        let nextEpoch = try generator.alias(
            for: binding,
            at: start.addingTimeInterval(300)
        )

        #expect(first == sameEpoch)
        #expect(first != nextEpoch)
        #expect(first.utf8.count == 32)
        #expect(!first.contains(binding.bindingID))
        #expect(!first.contains(binding.endpointID.endpointID))
    }

    @Test
    func aliasBindsSecretGenerationAndEveryPeerIdentityField() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_001)
        let binding = try makeBinding()
        let baseline = try makeGenerator(keyByte: 7, generation: 3)
            .alias(for: binding, at: date)
        let changedKey = try makeGenerator(keyByte: 8, generation: 3)
            .alias(for: binding, at: date)
        let changedGeneration = try makeGenerator(keyByte: 7, generation: 4)
            .alias(for: binding, at: date)
        let changedIdentity = try makeGenerator(keyByte: 7, generation: 3)
            .alias(
                for: makeBinding(endpointByte: "b"),
                at: date
            )

        #expect(Set([baseline, changedKey, changedGeneration, changedIdentity]).count == 4)
    }

    @Test
    func resolverAcceptsClockBoundaryButRejectsUnknownAndAmbiguousInput() throws {
        let generator = try makeGenerator(keyByte: 7, generation: 3)
        let binding = try makeBinding()
        let date = Date(timeIntervalSince1970: 1_800_000_001)
        let previous = try generator.alias(
            for: binding,
            at: date.addingTimeInterval(-300)
        )

        #expect(
            try generator.binding(
                matching: previous,
                among: [binding],
                at: date
            ) == binding
        )
        #expect(
            try generator.binding(
                matching: String(repeating: "0", count: 32),
                among: [binding],
                at: date
            ) == nil
        )
        #expect(
            try generator.binding(
                matching: "not-an-alias",
                among: [binding],
                at: date
            ) == nil
        )
    }

    @Test
    func nonMacBindingsCannotBecomeAdvertisedServices() throws {
        let generator = try makeGenerator(keyByte: 7, generation: 3)
        let binding = try makeBinding(platform: .ios)

        #expect(throws: CmxIrohLANRendezvousAliasError.unsupportedPlatform) {
            try generator.alias(
                for: binding,
                at: Date(timeIntervalSince1970: 1_800_000_001)
            )
        }
    }

    private func makeGenerator(
        keyByte: UInt8,
        generation: Int
    ) throws -> CmxIrohLANRendezvousAliasGenerator {
        let key = Data(repeating: keyByte, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let data = try JSONSerialization.data(withJSONObject: [
            "generation": generation,
            "key": key,
        ])
        return try CmxIrohLANRendezvousAliasGenerator(
            rendezvous: JSONDecoder().decode(CmxIrohLANRendezvous.self, from: data)
        )
    }

    private func makeBinding(
        endpointByte: Character = "a",
        platform: CmxIrohPlatform = .mac
    ) throws -> CmxIrohBrokerBindingMetadata {
        try CmxIrohBrokerBindingMetadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174010",
            deviceID: "123e4567-e89b-42d3-a456-426614174011",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174012",
            tag: "cmux-ios-v0",
            platform: platform,
            endpointID: CmxIrohPeerIdentity(
                endpointID: String(repeating: endpointByte, count: 64)
            ),
            identityGeneration: 4
        )
    }
}
