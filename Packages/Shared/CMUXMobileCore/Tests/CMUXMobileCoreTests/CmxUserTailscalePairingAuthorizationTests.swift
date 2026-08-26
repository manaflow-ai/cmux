import Testing
@testable import CMUXMobileCore

@Suite struct CmxUserTailscalePairingAuthorizationTests {
    @Test func canonicalizesNumericIPv6AndAuthorizesExactDestination() throws {
        let authorization = try CmxUserTailscalePairingAuthorization(
            host: "fd7a:115c:a1e0:0:0:0:0:1234",
            port: 58_465
        )

        #expect(authorization.host == "fd7a:115c:a1e0::1234")
        #expect(authorization.port == 58_465)
        #expect(authorization.authorizes(host: "fd7a:115c:a1e0::1234", port: 58_465))
    }

    @Test func rejectsNonTailscaleDestinations() {
        #expect(throws: CmxUserTailscalePairingAuthorizationError.invalidHost) {
            _ = try CmxUserTailscalePairingAuthorization(
                host: "work-mac.tailnet.ts.net",
                port: 58_465
            )
        }
        #expect(throws: CmxUserTailscalePairingAuthorizationError.invalidHost) {
            _ = try CmxUserTailscalePairingAuthorization(
                host: "192.168.1.20",
                port: 58_465
            )
        }
        #expect(throws: CmxUserTailscalePairingAuthorizationError.invalidPort(0)) {
            _ = try CmxUserTailscalePairingAuthorization(
                host: "100.71.210.41",
                port: 0
            )
        }
    }

    @Test func refusesEveryDestinationSubstitution() throws {
        let authorization = try CmxUserTailscalePairingAuthorization(
            host: "100.71.210.41",
            port: 58_465
        )

        #expect(!authorization.authorizes(host: "100.71.210.42", port: 58_465))
        #expect(!authorization.authorizes(host: "100.71.210.41", port: 58_466))
        #expect(!authorization.authorizes(host: "work-mac.tailnet.ts.net", port: 58_465))
    }
}
