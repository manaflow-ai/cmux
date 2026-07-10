import Foundation
import Testing
@testable import CMUXMobileCore

private let canonicalEndpointID = String(repeating: "a", count: 64)

private func profile(
    _ source: CmxIrohPathHintSource,
    _ profileID: String = "default"
) throws -> CmxIrohNetworkProfileKey {
    try CmxIrohNetworkProfileKey(source: source, profileID: profileID)
}

@Test func irohEndpointIDRequiresCanonicalLowercaseHex() throws {
    #expect((try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)).endpointID == canonicalEndpointID)
    for invalid in [
        "",
        String(repeating: "a", count: 63),
        String(repeating: "a", count: 65),
        String(repeating: "A", count: 64),
        String(repeating: "g", count: 64),
    ] {
        #expect(throws: CmxIrohPeerIdentityError.nonCanonicalEndpointID) {
            _ = try CmxIrohPeerIdentity(endpointID: invalid)
        }
    }
}
@Test func attachTicketChoosesFirstSupportedRouteByPriority() throws {
    let iroh = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            id: canonicalEndpointID,
            relayHint: "relay-1",
            directAddrs: ["192.168.1.20:3478"],
            relayURL: "https://relay.example.test"
        ),
        priority: 0
    )
    let tailscale = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831),
        priority: 1
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: "terminal-1",
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        routes: [tailscale, iroh],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )

    #expect(ticket.preferredRoute(supportedKinds: [.tailscale, .iroh]) == iroh)
    #expect(ticket.preferredRoute(supportedKinds: [.websocket]) == nil)
    #expect(ticket.preferredRoute(supportedKinds: []) == nil)
}

@Test func irohPeerIdentityIsIndependentFromOrderedProviderPathHints() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let relay = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.example.test",
        source: .native,
        privacyScope: .publicInternet
    )
    let expiredLAN = try CmxIrohPathHint(
        kind: .directAddress,
        value: "192.168.1.20:49152",
        source: .lan,
        privacyScope: .localNetwork,
        observedAt: now.addingTimeInterval(-60),
        expiresAt: now.addingTimeInterval(-1),
        networkProfile: profile(.lan, "studio")
    )
    let tailscale = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.1.2:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60),
        networkProfile: profile(.tailscale, "production")
    )
    let customVPN = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.10.0.8:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: now,
        expiresAt: now.addingTimeInterval(30),
        networkProfile: profile(.customVPN, "corp")
    )
    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
        pathHints: [tailscale, expiredLAN, relay, customVPN]
    )

    #expect(endpoint.irohPeerIdentity == (try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)))
    #expect(tailscale.use == .fallbackOnly)
    #expect(expiredLAN.use == .fallbackOnly)
    #expect(customVPN.use == .fallbackOnly)
    #expect(relay.use == .primary)
    let firstPhaseOnly = try #require(endpoint.irohDialPlan(
        at: now,
        managedRelayURLs: [relay.value]
    ))
    #expect(firstPhaseOnly.publicPaths == [relay])
    #expect(firstPhaseOnly.privateFallbackPaths.isEmpty)

    let fullPlan = try #require(endpoint.irohDialPlan(
        at: now,
        managedRelayURLs: [relay.value],
        activeNetworkProfiles: [
            profile(.tailscale, "production"),
            profile(.customVPN, "corp"),
        ]
    ))
    #expect(fullPlan.publicPaths == [relay])
    #expect(fullPlan.privateFallbackPaths == [tailscale, customVPN])
}

@Test func privateProviderHintsRequireMatchingScopeAndExpiry() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    #expect(throws: CmxIrohPathHintError.incompatiblePrivacyScope(
        source: .tailscale,
        scope: .publicInternet
    )) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "8.8.8.8:49152",
            source: .tailscale,
            privacyScope: .publicInternet,
            expiresAt: expiry
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintObservation) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "192.168.1.20:49152",
            source: .lan,
            privacyScope: .localNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintObservation) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .native,
            privacyScope: .privateNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintExpiry) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-60),
            networkProfile: profile(.customVPN)
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintNetworkProfile) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-60),
            expiresAt: expiry
        )
    }
    #expect(throws: CmxIrohPathHintError.privateHintTTLExceedsMaximum) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-(CmxIrohPathHint.maximumPrivateHintTTL + 1)),
            expiresAt: expiry,
            networkProfile: profile(.customVPN)
        )
    }
    #expect(throws: CmxIrohPathHintError.networkProfileSourceMismatch) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-60),
            expiresAt: expiry,
            networkProfile: profile(.tailscale)
        )
    }
}

@Test func irohPeerRouteCapsPathHintsAtSixteen() throws {
    let hint = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.example.test/",
        source: .native,
        privacyScope: .publicInternet
    )
    let maximum = CmxAttachEndpoint.maximumIrohPathHintCount
    let endpointID = try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)

    _ = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            identity: endpointID,
            pathHints: Array(repeating: hint, count: maximum)
        )
    )

    #expect(throws: CmxAttachRouteError.tooManyPeerPathHints(
        actual: maximum + 1,
        maximum: maximum
    )) {
        _ = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: endpointID,
                pathHints: Array(repeating: hint, count: maximum + 1)
            )
        )
    }
}

@Test func directPathHintsAcceptOnlyCanonicalIPSocketAddresses() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let ipv4 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
    let ipv6 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[fd7a:115c:a1e0::1]:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.tailscale)
    )
    #expect(ipv4.value == "10.0.0.4:49152")
    #expect(ipv6.value == "[fd7a:115c:a1e0::1]:49152")

    for malformed in [
        "mac.tailnet.ts.net:49152",
        "https://10.0.0.4:49152",
        "user@10.0.0.4:49152",
        "10.0.0.0/24:49152",
        "10.0.0.4",
        "10.0.0.4:0",
        "010.0.0.4:49152",
        "[fe80::1%en0]:49152",
    ] {
        #expect(throws: CmxIrohPathHintError.invalidDirectAddress) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: malformed,
                source: .customVPN,
                privacyScope: .privateNetwork,
                observedAt: expiry.addingTimeInterval(-60),
                expiresAt: expiry,
                networkProfile: profile(.customVPN)
            )
        }
    }
}

@Test func directPathHintsRejectNonPeerAndMetadataAddresses() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    for forbidden in [
        "0.0.0.0:49152",
        "127.0.0.1:49152",
        "224.0.0.1:49152",
        "255.255.255.255:49152",
        "169.254.169.254:49152",
        "[::]:49152",
        "[::1]:49152",
        "[ff02::1]:49152",
        "[fe80::1]:49152",
        "[fd00:ec2::254]:49152",
    ] {
        #expect(throws: CmxIrohPathHintError.forbiddenDirectAddress) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: forbidden,
                source: .native,
                privacyScope: .localNetwork,
                observedAt: expiry.addingTimeInterval(-60),
                expiresAt: expiry,
                networkProfile: profile(.native)
            )
        }
    }

    let legitimateLinkLocal = try CmxIrohPathHint(
        kind: .directAddress,
        value: "169.254.42.7:49152",
        source: .lan,
        privacyScope: .localNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.lan)
    )
    #expect(legitimateLinkLocal.value == "169.254.42.7:49152")
}

@Test func publicDirectPathHintsRequireGloballyRoutableAddresses() throws {
    let publicIPv4 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "8.8.8.8:49152",
        source: .native,
        privacyScope: .publicInternet
    )
    let publicIPv6 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[2606:4700:4700::1111]:49152",
        source: .native,
        privacyScope: .publicInternet
    )
    #expect(publicIPv4.use == .primary)
    #expect(publicIPv6.use == .primary)

    for nonGlobal in [
        "10.0.0.4:49152",
        "172.16.0.4:49152",
        "192.168.1.4:49152",
        "100.64.1.4:49152",
        "169.254.42.7:49152",
        "192.0.2.4:49152",
        "198.18.0.4:49152",
        "198.51.100.4:49152",
        "203.0.113.4:49152",
        "[fd7a:115c:a1e0::1]:49152",
        "[2001:db8::1]:49152",
        "[3fff::1]:49152",
    ] {
        #expect(throws: CmxIrohPathHintError.nonGlobalPublicDirectAddress) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: nonGlobal,
                source: .native,
                privacyScope: .publicInternet
            )
        }
    }

    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "169.254.42.7:49152",
        source: .lan,
        privacyScope: .localNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.lan)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[fd7a:115c:a1e0::1]:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.tailscale)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "192.0.2.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[2001:db8::1]:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
}

@Test func relayPathHintsAcceptOnlyCredentialFreeRootHTTPSURLs() throws {
    let valid = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
        source: .native,
        privacyScope: .publicInternet
    )
    #expect(valid.use == .primary)

    for unsafe in [
        "http://relay.example.test/",
        "https://user:secret@relay.example.test/",
        "https://relay.example.test/admin",
        "https://relay.example.test/?token=secret",
        "https://169.254.169.254/",
        "https://169.254.42.7/",
        "https://10.0.0.1/",
        "https://127.0.0.1/",
        "https://[::1]/",
        "https://[fd7a:115c:a1e0::1]/",
        "https://relay.local/",
        "https://0177.0.0.1/",
        "https://0x7f.0.0.1/",
        "https://127.1/",
        "https://localhost./",
        "https://relay..example.test/",
        "https://-relay.example.test/",
        "https://relay.example-.test/",
        "https://relay.example.123/",
        "relay.example.test",
    ] {
        #expect(throws: CmxIrohPathHintError.unsafeRelayURL) {
            _ = try CmxIrohPathHint(
                kind: .relayURL,
                value: unsafe,
                source: .native,
                privacyScope: .publicInternet
            )
        }
    }

    #expect(throws: CmxIrohPathHintError.relayHintRequiresNativePublicSource) {
        _ = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .privateNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.relayHintRequiresNativePublicSource) {
        _ = try CmxIrohPathHint(
            kind: .relayIdentifier,
            value: "use1",
            source: .tailscale,
            privacyScope: .privateNetwork
        )
    }
}
