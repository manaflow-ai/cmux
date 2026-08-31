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

    @Test func canonicalizesDirectIPv4AndIPv6Spellings() throws {
        let ipv4 = try CmxUserTailscalePairingAuthorization(
            host: "192.168.1.20.",
            port: 58_465
        )
        #expect(ipv4.host == "192.168.1.20")

        let ipv6 = try CmxUserTailscalePairingAuthorization(
            host: "[fe80:0:0:0:0:0:0:1]",
            port: 58_465
        )
        #expect(ipv6.host == "fe80::1")
        #expect(ipv6.authorizes(host: "fe80::1", port: 58_465))
    }

    @Test(arguments: [
        "work-mac.tailnet.ts.net",
        "work-mac",
        "192.168.1.20",
        "devbox.local",
    ])
    func acceptsValidatedMagicDNSAndDirectHosts(_ host: String) throws {
        let authorization = try CmxUserTailscalePairingAuthorization(
            host: host,
            port: 58_465
        )

        #expect(authorization.authorizes(host: host, port: 58_465))
        #expect(!authorization.authorizes(host: "other-(host)", port: 58_465))
    }

    @Test func rejectsMalformedHosts() {
        #expect(throws: CmxUserTailscalePairingAuthorizationError.invalidHost) {
            _ = try CmxUserTailscalePairingAuthorization(
                host: "https://work-mac.tailnet.ts.net/path",
                port: 58_465
            )
        }
        #expect(throws: CmxUserTailscalePairingAuthorizationError.invalidHost) {
            _ = try CmxUserTailscalePairingAuthorization(
                host: "192.168.001.20",
                port: 58_465
            )
        }
        #expect(throws: CmxUserTailscalePairingAuthorizationError.invalidHost) {
            _ = try CmxUserTailscalePairingAuthorization(
                host: "[work-mac]",
                port: 58_465
            )
        }
        #expect(throws: CmxUserTailscalePairingAuthorizationError.invalidHost) {
            _ = try CmxUserTailscalePairingAuthorization(
                host: "127.0.0.1",
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
