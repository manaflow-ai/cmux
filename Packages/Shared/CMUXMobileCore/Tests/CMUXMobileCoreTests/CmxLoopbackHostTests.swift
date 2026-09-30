import Foundation
import Testing
@testable import CMUXMobileCore

/// Coverage for the shared loopback-host classifier.
@Suite struct CmxLoopbackHostTests {
    @Test(arguments: [
        "127.0.0.1", " 127.0.0.1 ", "127.0.0.2", "127.255.255.255",
        "localhost", "LocalHost", "dev.localhost",
        "localhost.", "dev.localhost.",
        "::1", "[::1]", "::ffff:127.0.0.1", "[::ffff:127.0.0.1]",
        // Canonical-equivalent spellings: the classifier parses address
        // bytes with the resolver's own semantics, so every spelling that
        // dials the local machine classifies as loopback.
        "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]", "[::1%lo0]",
        "::ffff:7f00:1", "::127.0.0.1",
        "127.1", "127.0.1", "2130706433", "0x7f.0.0.1", "0177.0.0.1",
        // 0.0.0.0/8 and :: connect to the local machine too.
        "0.0.0.0", "0", "::",
        // inet_aton reads "127.0.0" as 127.0.0.0.
        "127.0.0",
    ])
    func matchesLoopbackSpellings(host: String) {
        #expect(CmxLoopbackHost().matches(host))
    }

    @Test(arguments: [
        "100.64.0.5", "128.0.0.1", "126.255.255.255", "10.0.0.1",
        "lawrences-mac.tail1234.ts.net", "localhost.example.com",
        "fd7a:115c:a1e0::1", "::ffff:100.64.0.5", "127.0.0.0.1", "",
        // 128.1 -> 128.0.0.1 and 1681915909 -> 100.64.0.5: legacy numeric
        // forms that do NOT land in a self-dialing range stay accepted.
        "128.1", "1681915909",
    ])
    func rejectsNonLoopbackHosts(host: String) {
        #expect(!CmxLoopbackHost().matches(host))
    }

    @Test func classifiesRoutesByKindAndHost() throws {
        let devLoopback = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "100.64.0.5", port: 58465)
        )
        #expect(CmxLoopbackHost().matches(devLoopback))

        let loopbackTailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        #expect(CmxLoopbackHost().matches(loopbackTailscale))

        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 58465)
        )
        #expect(!CmxLoopbackHost().matches(tailscale))
    }
}
