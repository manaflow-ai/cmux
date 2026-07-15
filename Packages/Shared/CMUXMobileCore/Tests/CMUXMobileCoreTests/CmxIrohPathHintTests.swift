import Foundation
import Testing
@testable import CMUXMobileCore

private let canonicalEndpointID = String(repeating: "a", count: 64)
private let canonicalNetworkProfileID = String(repeating: "b", count: 64)

private func profile(
    _ source: CmxIrohPathHintSource,
    _ profileID: String = "default"
) throws -> CmxIrohNetworkProfileKey {
    let hex = profileID.utf8.map { String(format: "%02x", $0) }.joined()
    let opaqueID = String((hex + String(repeating: "0", count: 64)).prefix(64))
    return try CmxIrohNetworkProfileKey(source: source, profileID: opaqueID)
}

@Test func irohEndpointIDRequiresCanonicalLowercaseHex() throws {
    let identity = try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)
    #expect(identity.endpointID == canonicalEndpointID)
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

@Test func networkProfileIDRequiresOpaqueCanonicalLowercaseHex() throws {
    #expect(
        (try CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: canonicalNetworkProfileID
        )).profileID == canonicalNetworkProfileID
    )

    for invalid in [
        "production",
        String(repeating: "a", count: 63),
        String(repeating: "a", count: 65),
        String(repeating: "A", count: 64),
        String(repeating: "g", count: 64),
    ] {
        #expect(throws: CmxIrohNetworkProfileKeyError.invalidProfileID) {
            _ = try CmxIrohNetworkProfileKey(source: .tailscale, profileID: invalid)
        }
    }
}

@Test func nativePathHintsCannotAuthorizePrivateOrLocalNetworks() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    for scope in [CmxIrohPathHintPrivacyScope.localNetwork, .privateNetwork] {
        #expect(throws: CmxIrohPathHintError.incompatiblePrivacyScope(
            source: .native,
            scope: scope
        )) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: "10.0.0.4:49152",
                source: .native,
                privacyScope: scope,
                observedAt: now,
                expiresAt: now.addingTimeInterval(60),
                networkProfile: try CmxIrohNetworkProfileKey(
                    source: .native,
                    profileID: canonicalNetworkProfileID
                )
            )
        }
    }
}

@Test func serializedIPv4LinkLocalHintsAreNotDialable() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    #expect(throws: CmxIrohPathHintError.forbiddenDirectAddress) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "169.254.42.7:49152",
            source: .lan,
            privacyScope: .localNetwork,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60),
            networkProfile: try CmxIrohNetworkProfileKey(
                source: .lan,
                profileID: canonicalNetworkProfileID
            )
        )
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

    let expectedIdentity = try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)
    #expect(endpoint.irohPeerIdentity == expectedIdentity)
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
    #expect(throws: CmxIrohPathHintError.incompatiblePrivacyScope(
        source: .native,
        scope: .privateNetwork
    )) {
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

    #expect(throws: CmxIrohPathHintError.forbiddenDirectAddress) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "169.254.42.7:49152",
            source: .lan,
            privacyScope: .localNetwork,
            observedAt: expiry.addingTimeInterval(-60),
            expiresAt: expiry,
            networkProfile: profile(.lan)
        )
    }
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
