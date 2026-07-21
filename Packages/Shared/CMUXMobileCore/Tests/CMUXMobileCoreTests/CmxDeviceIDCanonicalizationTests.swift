import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxDeviceIDCanonicalizationTests {
    private let uppercaseUUID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    private let lowercaseUUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @Test func canonicalizerLowercasesOnlyUUIDDeviceIDs() {
        #expect(cmxCanonicalDeviceID(uppercaseUUID) == lowercaseUUID)
        #expect(cmxCanonicalDeviceID(lowercaseUUID) == lowercaseUUID)
        #expect(cmxCanonicalDeviceID("Legacy-Mac-ID") == "Legacy-Mac-ID")
        #expect(cmxCanonicalDeviceID(" legacy-id ") == " legacy-id ")
    }

    @Test func attachTicketCanonicalizesInitializerAndLegacyWireIdentity() throws {
        let route = try CmxAttachRoute(
            id: "manual",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.2", port: 58_465)
        )
        let initialized = try CmxAttachTicket(
            workspaceID: "workspace",
            terminalID: nil,
            macDeviceID: uppercaseUUID,
            macDisplayName: "Studio",
            routes: [route]
        )
        #expect(initialized.macDeviceID == lowercaseUUID)

        let data = Data("""
        {
          "version": 1,
          "workspaceID": "workspace",
          "macDeviceID": "\(uppercaseUUID)",
          "routes": [
            {
              "id": "manual",
              "kind": "tailscale",
              "endpoint": { "type": "host_port", "host": "100.64.0.2", "port": 58465 },
              "priority": 0
            }
          ]
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(CmxAttachTicket.self, from: data)
        #expect(decoded.macDeviceID == lowercaseUUID)
    }

    @Test func pairingPayloadCanonicalizesUUIDAndPreservesOpaqueIdentity() throws {
        let expiresAt = Date().addingTimeInterval(60)
        let uuidPayload = try MobileSyncPairingPayload(
            macDeviceID: uppercaseUUID,
            macDisplayName: nil,
            host: "100.64.0.2",
            port: 58_465,
            expiresAt: expiresAt,
            transport: .tailscale
        )
        let opaquePayload = try MobileSyncPairingPayload(
            macDeviceID: "Legacy-Mac-ID",
            macDisplayName: nil,
            host: "100.64.0.2",
            port: 58_465,
            expiresAt: expiresAt,
            transport: .tailscale
        )

        #expect(uuidPayload.macDeviceID == lowercaseUUID)
        #expect(opaquePayload.macDeviceID == "Legacy-Mac-ID")
    }
}
