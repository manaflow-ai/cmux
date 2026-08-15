import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohRuntimeConfigurationDeviceIDTests {
    @Test
    func runtimeConfigurationsCanonicalizeUUIDsWithoutFoldingOpaqueDeviceIDs() throws {
        let fixture = try HostRuntimeFixture()
        let uppercaseUUID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercaseUUID = uppercaseUUID.lowercased()

        let uuidHost = hostConfiguration(deviceID: uppercaseUUID, fixture: fixture)
        let opaqueHost = hostConfiguration(deviceID: "Legacy-Mac-ID", fixture: fixture)
        let uuidClient = clientConfiguration(deviceID: uppercaseUUID, fixture: fixture)
        let opaqueClient = clientConfiguration(deviceID: "Legacy-iOS-ID", fixture: fixture)

        #expect(uuidHost.deviceID == lowercaseUUID)
        #expect(opaqueHost.deviceID == "Legacy-Mac-ID")
        #expect(uuidClient.deviceID == lowercaseUUID)
        #expect(opaqueClient.deviceID == "Legacy-iOS-ID")
    }

    private func hostConfiguration(
        deviceID: String,
        fixture: HostRuntimeFixture
    ) -> CmxIrohHostRuntimeConfiguration {
        CmxIrohHostRuntimeConfiguration(
            accountID: "account-a",
            deviceID: deviceID,
            appInstanceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            tag: "test",
            displayName: nil,
            identity: fixture.identity,
            pairingEnabled: true,
            capabilities: [],
            managedRelayURLs: []
        )
    }

    private func clientConfiguration(
        deviceID: String,
        fixture: HostRuntimeFixture
    ) -> CmxIrohClientRuntimeConfiguration {
        CmxIrohClientRuntimeConfiguration(
            accountID: "account-a",
            deviceID: deviceID,
            appInstanceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            tag: "test",
            displayName: nil,
            identity: fixture.identity,
            capabilities: [],
            managedRelayURLs: []
        )
    }
}
