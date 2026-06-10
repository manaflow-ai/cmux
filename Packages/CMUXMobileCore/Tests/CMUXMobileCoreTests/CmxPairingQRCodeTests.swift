import Foundation
import Testing
@testable import CMUXMobileCore

/// Coverage for the minimal v2 pairing-QR grammar: bare Tailscale
/// `host:port` routes in the URL query, nothing else.
@Suite struct CmxPairingQRCodeTests {
    private func tailscaleRoute(
        index: Int,
        host: String,
        port: Int = 58465
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: index == 0 ? "tailscale" : "tailscale_\(index + 1)",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: 10 + index * 10
        )
    }

    private func pairingTicket(routes: [CmxAttachRoute]) throws -> CmxAttachTicket {
        // Exactly what the Mac's ticket store mints for the pairing window:
        // unscoped, with identity/expiry/token fields the QR must NOT carry.
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-device-uuid",
            macDisplayName: "Lawrence's Mac",
            routes: routes,
            expiresAt: Date().addingTimeInterval(600),
            authToken: "minted-but-never-in-the-qr"
        )
    }

    private func components(_ url: String) throws -> URLComponents {
        let parsed = try #require(URL(string: url))
        return try #require(URLComponents(url: parsed, resolvingAgainstBaseURL: false))
    }

    @Test func roundTripsSingleRoute() throws {
        let ticket = try pairingTicket(routes: [
            try tailscaleRoute(index: 0, host: "100.64.0.5"),
        ])
        let url = try #require(CmxPairingQRCode.encode(ticket))
        #expect(url == "cmux-ios://attach?v=2&r=100.64.0.5:58465")

        let decoded = try CmxPairingQRCode.decode(try components(url))
        #expect(decoded.routes == ticket.routes)
        #expect(decoded.workspaceID == "")
        #expect(decoded.terminalID == nil)
        // Identity, expiry, and token are deliberately absent: the host
        // reports identity post-handshake, and nothing in the QR authorizes.
        #expect(decoded.macDeviceID == "")
        #expect(decoded.macDisplayName == nil)
        #expect(decoded.expiresAt == nil)
        #expect(decoded.authToken == nil)
    }

    @Test func roundTripsMagicDNSPlusIPRoutes() throws {
        let routes = [
            try tailscaleRoute(index: 0, host: "lawrences-mac.tail1234.ts.net"),
            try tailscaleRoute(index: 1, host: "100.64.0.5"),
        ]
        let ticket = try pairingTicket(routes: routes)
        let url = try #require(CmxPairingQRCode.encode(ticket))

        let decoded = try CmxPairingQRCode.decode(try components(url))
        #expect(decoded.routes == routes)
        // Synthesized ids and priorities mirror the Mac's route resolver, so
        // route preference is preserved without encoding either field.
        #expect(decoded.routes.map(\.id) == ["tailscale", "tailscale_2"])
        #expect(decoded.routes.map(\.priority) == [10, 20])
    }

    @Test func roundTripsIPv6LiteralThroughRealURLParsing() throws {
        let route = try tailscaleRoute(index: 0, host: "fd7a:115c:a1e0::1")
        let ticket = try pairingTicket(routes: [route])
        let url = try #require(CmxPairingQRCode.encode(ticket))

        let decoded = try CmxPairingQRCode.decode(try components(url))
        #expect(decoded.routes == [route])
    }

    @Test func encodeDropsDevLoopbackRouteFromDebugMacTicket() throws {
        // A DEBUG Mac's pairing ticket always carries the dev loopback route.
        // The QR must encode only the Tailscale routes: a scanned code
        // pointing at 127.0.0.1 makes the phone dial itself (and dialing it
        // first added the whole request timeout to scan-to-pair latency).
        let loopback = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465),
            priority: 0
        )
        let tailscale = try tailscaleRoute(index: 0, host: "100.64.0.5")
        let ticket = try pairingTicket(routes: [loopback, tailscale])

        let url = try #require(CmxPairingQRCode.encode(ticket))
        #expect(url == "cmux-ios://attach?v=2&r=100.64.0.5:58465")
        let decoded = try CmxPairingQRCode.decode(try components(url))
        #expect(decoded.routes == [tailscale])
    }

    @Test func ticketsOutsideTheMinimalGrammarDoNotEncode() throws {
        let tailscale = try tailscaleRoute(index: 0, host: "100.64.0.5")
        // Workspace-scoped tickets keep the lossless compact payload.
        let scoped = try CmxAttachTicket(
            workspaceID: "workspace-1",
            terminalID: nil,
            macDeviceID: "mac",
            macDisplayName: nil,
            routes: [tailscale]
        )
        #expect(CmxPairingQRCode.encode(scoped) == nil)
        #expect(!CmxPairingQRCode.canEncode(scoped))

        // Loopback-only dev tickets have nothing a phone could dial.
        let loopbackOnly = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac",
            macDisplayName: nil,
            routes: [
                try CmxAttachRoute(
                    id: "debug_loopback",
                    kind: .debugLoopback,
                    endpoint: .hostPort(host: "127.0.0.1", port: 58465)
                ),
            ]
        )
        #expect(CmxPairingQRCode.encode(loopbackOnly) == nil)

        // Custom route ids cannot be resynthesized by the decoder.
        let customID = try pairingTicket(routes: [
            try CmxAttachRoute(
                id: "my-route",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.64.0.5", port: 58465),
                priority: 10
            ),
        ])
        #expect(CmxPairingQRCode.encode(customID) == nil)

        // A Tailscale-kind route that somehow names a loopback host is a
        // weak QR and must not encode.
        let loopbackTailscale = try pairingTicket(routes: [
            try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "127.0.0.1", port: 58465),
                priority: 10
            ),
        ])
        #expect(CmxPairingQRCode.encode(loopbackTailscale) == nil)
    }

    @Test(arguments: [
        "127.0.0.1",
        "127.0.0.2",
        "127.255.255.255",
        "localhost",
        "localhost.",
        "sub.localhost",
        "LOCALHOST",
        "::1",
        "0:0:0:0:0:0:0:1",
        "::ffff:127.0.0.1",
        // Equivalent spellings the resolver dials as loopback: the
        // classifier parses bytes, so these cannot slip past as "names".
        "127.1",
        "2130706433",
        "0x7f.0.0.1",
        "0.0.0.0",
        "::",
        "::ffff:7f00:1",
    ])
    func decodeRejectsLoopbackHosts(host: String) throws {
        let encodedHost = host.contains(":") ? "[\(host)]" : host
        let url = "cmux-ios://attach?v=2&r=\(encodedHost):58465"
        #expect(throws: MobileSyncPairingPayloadError.loopbackRouteRejected) {
            try CmxPairingQRCode.decode(try components(url))
        }
    }

    @Test func decodeRejectsLoopbackEvenWhenARealRouteIsPresent() throws {
        // Hostile half-and-half codes fail closed, not "dial the good half".
        let url = "cmux-ios://attach?v=2&r=100.64.0.5:58465&r=127.0.0.1:58465"
        #expect(throws: MobileSyncPairingPayloadError.loopbackRouteRejected) {
            try CmxPairingQRCode.decode(try components(url))
        }
    }

    @Test func decodeRejectsMalformedRoutes() throws {
        let malformed = [
            "cmux-ios://attach?v=2",
            "cmux-ios://attach?v=2&r=",
            "cmux-ios://attach?v=2&r=hostonly",
            "cmux-ios://attach?v=2&r=host:0",
            "cmux-ios://attach?v=2&r=host:99999",
            "cmux-ios://attach?v=2&r=host:not-a-port",
            "cmux-ios://attach?v=2&r=[::1:58465",
        ]
        for url in malformed {
            #expect(throws: (any Error).self, "\(url) should not decode") {
                try CmxPairingQRCode.decode(try components(url))
            }
        }
    }

    @Test func decodeCapsHostileRouteCounts() throws {
        let routes = (0..<(CmxPairingQRCode.maximumRouteCount + 1))
            .map { "r=100.64.0.\($0 + 1):58465" }
            .joined(separator: "&")
        #expect(throws: MobileSyncPairingPayloadError.invalidURL) {
            try CmxPairingQRCode.decode(try components("cmux-ios://attach?v=2&\(routes)"))
        }
    }

    @Test func versionedURLDetectionDistinguishesGrammars() throws {
        #expect(CmxPairingQRCode.isPairingCodeURLString("cmux-ios://attach?v=2&r=100.64.0.5:58465"))
        #expect(!CmxPairingQRCode.isPairingCodeURLString("cmux-ios://attach?v=1&payload=abc"))
        #expect(!CmxPairingQRCode.isPairingCodeURLString("cmux-ios://pair?v=1&payload=abc"))
        #expect(!CmxPairingQRCode.isPairingCodeURLString("https://example.com?v=2"))
        #expect(!CmxPairingQRCode.isPairingCodeURLString("not a url"))
    }

    @Test func decodedTicketStillPairsLongAfterMint() throws {
        // The grammar has no expiry field at all, so a code that sat on the
        // Mac's screen for 10+ minutes still validates and is never expired.
        let url = "cmux-ios://attach?v=2&r=100.64.0.5:58465"
        let decoded = try CmxPairingQRCode.decode(try components(url))
        #expect(decoded.expiresAt == nil)
        #expect(!decoded.isExpired(at: Date.distantFuture))
        // validate() is structural only; re-running it later cannot fail.
        try decoded.validate()
    }

    /// Prints the payload-size + QR-version drop from the real encoders, so
    /// the win is visible in test output. Binary-mode ECC-L capacities per
    /// QR version (ISO/IEC 18004): the smallest version whose capacity fits
    /// the payload is what `CIFilter.qrCodeGenerator` emits at level L.
    @Test func reportsPayloadBytesAndQRVersionBeforeAfter() throws {
        func qrVersion(forByteCount count: Int) -> Int {
            let eccLByteCapacities = [
                17, 32, 53, 78, 106, 134, 154, 192, 230, 271,
                321, 367, 425, 458, 520, 586, 644, 718, 792, 858,
            ]
            for (index, capacity) in eccLByteCapacities.enumerated() where count <= capacity {
                return index + 1
            }
            return eccLByteCapacities.count + 1
        }

        let oneRoute = try pairingTicket(routes: [
            try tailscaleRoute(index: 0, host: "100.64.0.5"),
        ])
        let twoRoutes = try pairingTicket(routes: [
            try tailscaleRoute(index: 0, host: "lawrences-mac.tail1234.ts.net"),
            try tailscaleRoute(index: 1, host: "100.64.0.5"),
        ])

        for (label, ticket) in [("1-route", oneRoute), ("2-route", twoRoutes)] {
            let compactPayload = try CmxAttachTicketCompactCoder().encode(ticket)
            let base64 = compactPayload.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let before = "cmux-ios://attach?v=1&payload=\(base64)"
            let after = try #require(CmxPairingQRCode.encode(ticket))

            let beforeBytes = before.utf8.count
            let afterBytes = after.utf8.count
            print(
                "pairing-qr \(label): \(beforeBytes)B/QR v\(qrVersion(forByteCount: beforeBytes)) -> " +
                "\(afterBytes)B/QR v\(qrVersion(forByteCount: afterBytes)) (ECC L)"
            )
            #expect(afterBytes < beforeBytes)
            // The representative 2-route QR stays under 100 bytes / version 6.
            #expect(afterBytes < 100)
            #expect(qrVersion(forByteCount: afterBytes) <= 6)
        }
    }
}

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
        #expect(CmxLoopbackHost.matches(host))
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
        #expect(!CmxLoopbackHost.matches(host))
    }

    @Test func classifiesRoutesByKindAndHost() throws {
        let devLoopback = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "100.64.0.5", port: 58465)
        )
        #expect(CmxLoopbackHost.matches(devLoopback))

        let loopbackTailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        #expect(CmxLoopbackHost.matches(loopbackTailscale))

        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 58465)
        )
        #expect(!CmxLoopbackHost.matches(tailscale))
    }
}
