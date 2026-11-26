import Foundation
import Testing
@testable import CmuxIrxTransport

struct LegacyCompatibilityIdentityTests {
    private let physicalID = "11111111-1111-4111-8111-111111111111"
    private let installationID = "22222222-2222-4222-8222-222222222222"

    @Test func upgradeKeepsTheLegacyComputerSlotWithoutImportingItsKey() {
        let v2 = identity(seed: 2)
        let publication = LegacyCompatibilityService.compatibilityIdentity(
            from: v2, deviceID: physicalID
        )
        #expect(publication.deviceID == physicalID)
        #expect(publication.endpointIDHex == v2.endpointIDHex)
        #expect(publication.privateKeyData == v2.privateKeyData)
        #expect(v2.deviceID == installationID)
    }

    @Test func teamKeysRemainDistinctEvenWhenTheyPublishTheSameLegacyComputerSlot() {
        let first = LegacyCompatibilityService.compatibilityIdentity(from: identity(seed: 2), deviceID: physicalID)
        let second = LegacyCompatibilityService.compatibilityIdentity(from: identity(seed: 3), deviceID: physicalID)
        #expect(first.deviceID == second.deviceID)
        #expect(first.endpointIDHex != second.endpointIDHex)
        #expect(first.appInstanceID != second.appInstanceID)
    }

    @Test func existingBuggyPublicationCanBeIdentifiedExactlyForMigration() {
        let v2 = identity(seed: 2)
        let previous = LegacyCompatibilityService.compatibilityIdentity(from: v2)
        let corrected = LegacyCompatibilityService.compatibilityIdentity(from: v2, deviceID: physicalID)
        #expect(previous.deviceID == installationID)
        #expect(previous.deviceID != corrected.deviceID)
        #expect(previous.appInstanceID == corrected.appInstanceID)
        #expect(previous.endpointIDHex == corrected.endpointIDHex)
    }

    private func identity(seed: UInt8) -> IrxIdentity {
        IrxIdentity(privateKeyData: Data(repeating: seed, count: 32),
                    deviceID: installationID, appInstanceID: "v2-tuple")
    }
}
