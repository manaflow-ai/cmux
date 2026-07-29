import Testing
@testable import CMUXMobileCore

@Suite struct CmxLegacyTailscaleAuthorizationEvidenceTests {
    @Test func canonicalizesUUIDAndNumericIPv6() throws {
        let evidence = try CmxLegacyTailscaleAuthorizationEvidence(
            macDeviceID: "F4EC647C-9FA1-4B7F-8AB6-4261A8129738",
            host: "fd7a:115c:a1e0:0:0:0:0:1234",
            port: 58_465
        )

        #expect(evidence.macDeviceID == "f4ec647c-9fa1-4b7f-8ab6-4261a8129738")
        #expect(evidence.host == "fd7a:115c:a1e0::1234")
        #expect(evidence.port == 58_465)
        #expect(evidence.authorizes(
            macDeviceID: "F4EC647C-9FA1-4B7F-8AB6-4261A8129738",
            host: "fd7a:115c:a1e0::1234",
            port: 58_465
        ))
    }

    @Test func rejectsNonPeerInputs() {
        #expect(throws: CmxLegacyTailscaleAuthorizationEvidenceError.invalidMacDeviceID) {
            _ = try CmxLegacyTailscaleAuthorizationEvidence(
                macDeviceID: " mac-1",
                host: "100.71.210.41",
                port: 58_465
            )
        }
        #expect(throws: CmxLegacyTailscaleAuthorizationEvidenceError.invalidHost) {
            _ = try CmxLegacyTailscaleAuthorizationEvidence(
                macDeviceID: "mac-1",
                host: "work-mac.tailnet.ts.net",
                port: 58_465
            )
        }
        #expect(throws: CmxLegacyTailscaleAuthorizationEvidenceError.invalidHost) {
            _ = try CmxLegacyTailscaleAuthorizationEvidence(
                macDeviceID: "mac-1",
                host: "192.168.1.20",
                port: 58_465
            )
        }
        #expect(throws: CmxLegacyTailscaleAuthorizationEvidenceError.invalidPort(0)) {
            _ = try CmxLegacyTailscaleAuthorizationEvidence(
                macDeviceID: "mac-1",
                host: "100.71.210.41",
                port: 0
            )
        }
    }

    @Test func authorizesOnlyExactCanonicalBinding() throws {
        let evidence = try CmxLegacyTailscaleAuthorizationEvidence(
            macDeviceID: "mac-1",
            host: "100.71.210.41",
            port: 58_465
        )

        #expect(evidence.authorizes(
            macDeviceID: "mac-1",
            host: "100.71.210.41",
            port: 58_465
        ))
        #expect(!evidence.authorizes(
            macDeviceID: "mac-2",
            host: "100.71.210.41",
            port: 58_465
        ))
        #expect(!evidence.authorizes(
            macDeviceID: "mac-1",
            host: "100.71.210.42",
            port: 58_465
        ))
        #expect(!evidence.authorizes(
            macDeviceID: "mac-1",
            host: "100.71.210.41",
            port: 58_466
        ))
    }
}
