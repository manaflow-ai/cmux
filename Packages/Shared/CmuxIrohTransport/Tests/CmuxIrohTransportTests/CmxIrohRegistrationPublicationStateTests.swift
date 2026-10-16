import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh registration publication state")
struct CmxIrohRegistrationPublicationStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("relay path addition removal and replacement require publication at once")
    func changedPathsRequirePublication() throws {
        let first = try state(hints: [hint("https://relay-a.example/")])
        let spaced = now

        #expect(try state(hints: []).requiresPublication(after: first, now: spaced))
        #expect(
            try state(hints: [
                hint("https://relay-a.example/"),
                hint("https://relay-b.example/"),
            ]).requiresPublication(after: first, now: spaced)
        )
        #expect(
            try state(hints: [hint("https://relay-b.example/")])
                .requiresPublication(after: first, now: spaced)
        )
    }

    @Test("path reorder and timestamp churn stay silent before renewal")
    func metadataOnlyChangesStaySilent() throws {
        let first = try state(hints: [
            hint("https://relay-a.example/"),
            hint("https://relay-b.example/"),
        ])
        let reordered = try state(
            hints: [
                hint(
                    "https://relay-b.example/",
                    observedAt: now.addingTimeInterval(60),
                    expiresAt: now.addingTimeInterval(3_660)
                ),
                hint(
                    "https://relay-a.example/",
                    observedAt: now.addingTimeInterval(60),
                    expiresAt: now.addingTimeInterval(3_660)
                ),
            ],
            payloadNow: now.addingTimeInterval(60)
        )

        #expect(!reordered.requiresPublication(
            after: first,
            now: now.addingTimeInterval(60)
        ))
    }

    @Test("relay changes and direct address appearance publish at once; address churn is spaced")
    func stableChangesBypassSpacing() throws {
        let relayOnly = try state(hints: [hint("https://relay-a.example/")])
        let relayChanged = try state(
            hints: [hint("https://relay-b.example/")],
            payloadNow: now.addingTimeInterval(1)
        )
        #expect(relayChanged.publicationDecision(after: relayOnly, now: now.addingTimeInterval(1)) == .publish)
        let firstDirect = try state(
            hints: [hint("https://relay-a.example/"), directHint("8.8.8.8:4433")],
            payloadNow: now.addingTimeInterval(1)
        )
        #expect(firstDirect.publicationDecision(after: relayOnly, now: now.addingTimeInterval(1)) == .publish)
        let churned = try state(
            hints: [hint("https://relay-a.example/"), directHint("8.8.4.4:4433")],
            payloadNow: now.addingTimeInterval(2)
        )
        #expect(
            churned.publicationDecision(after: firstDirect, now: now.addingTimeInterval(2))
                == .deferred(until: now.addingTimeInterval(61))
        )
        let portsChanged = try state(
            hints: [hint("https://relay-a.example/"), directHint("8.8.4.4:4433")],
            ipv4Port: 50_001,
            payloadNow: now.addingTimeInterval(3)
        )
        #expect(portsChanged.publicationDecision(after: firstDirect, now: now.addingTimeInterval(3)) == .publish)
    }

    @Test("a changed path inside the spacing window is deferred to the end of the window")
    func changedPathsAreSpacedOut() throws {
        let published = try state(hints: [hint("https://relay-a.example/"), directHint("8.8.8.8:4433")])
        let changed = try state(
            hints: [hint("https://relay-a.example/"), directHint("8.8.4.4:4433")],
            payloadNow: now.addingTimeInterval(5)
        )
        #expect(
            changed.publicationDecision(after: published, now: now.addingTimeInterval(5))
                == .deferred(until: now.addingTimeInterval(60))
        )
        #expect(!changed.requiresPublication(after: published, now: now.addingTimeInterval(5)))
        #expect(
            changed.publicationDecision(after: published, now: now.addingTimeInterval(60))
                == .publish
        )
        #expect(changed.requiresPublication(after: published, now: now.addingTimeInterval(60)))
    }

    @Test("the broker-advertised spacing on the last publication wins over the default")
    func brokerSpacingApplies() throws {
        let published = try state(
            hints: [hint("https://relay-a.example/"), directHint("8.8.8.8:4433")],
            minimumPublicationSpacing: 120
        )
        let changed = try state(
            hints: [hint("https://relay-a.example/"), directHint("8.8.4.4:4433")],
            payloadNow: now.addingTimeInterval(90)
        )
        #expect(
            changed.publicationDecision(after: published, now: now.addingTimeInterval(90))
                == .deferred(until: now.addingTimeInterval(120))
        )
        let zeroSpacing = try state(
            hints: [hint("https://relay-a.example/"), directHint("8.8.8.8:4433")],
            minimumPublicationSpacing: 0
        )
        #expect(
            changed.publicationDecision(after: zeroSpacing, now: now.addingTimeInterval(1))
                == .publish
        )
    }

    @Test("first publication, renewals, and unchanged paths ignore the spacing window")
    func spacingDoesNotDelayRenewalOrFirstPublication() throws {
        let fresh = try state(hints: [hint("https://relay-a.example/")])
        #expect(fresh.publicationDecision(after: nil, now: now) == .publish)
        let unchanged = try state(hints: [hint("https://relay-a.example/")])
        #expect(
            unchanged.publicationDecision(after: fresh, now: now.addingTimeInterval(5))
                == .unchanged
        )
        let expiring = try state(hints: [
            hint("https://relay-a.example/", expiresAt: now.addingTimeInterval(320)),
        ])
        let changedAtRenewal = try state(
            hints: [hint("https://relay-a.example/", expiresAt: now.addingTimeInterval(320)), directHint("8.8.4.4:4433")],
            payloadNow: now.addingTimeInterval(20)
        )
        // Renewal is due at expiry minus the five-minute lead time, which is
        // inside the spacing window here; renewal still wins.
        #expect(
            changedAtRenewal.publicationDecision(after: expiring, now: now.addingTimeInterval(20))
                == .publish
        )
    }

    @Test("unchanged paths renew before expiry and within fifty minutes")
    func unchangedPathsRenewOnSchedule() throws {
        let expiring = try state(hints: [
            hint(
                "https://relay-a.example/",
                expiresAt: now.addingTimeInterval(1_800)
            ),
        ])
        let unchanged = try state(hints: [
            hint(
                "https://relay-a.example/",
                expiresAt: now.addingTimeInterval(1_800)
            ),
        ])

        #expect(!unchanged.requiresPublication(
            after: expiring,
            now: now.addingTimeInterval(1_499)
        ))
        #expect(unchanged.requiresPublication(
            after: expiring,
            now: now.addingTimeInterval(1_500)
        ))

        let noHints = try state(hints: [])
        #expect(!noHints.requiresPublication(
            after: noHints,
            now: now.addingTimeInterval(2_999)
        ))
        #expect(noHints.requiresPublication(
            after: noHints,
            now: now.addingTimeInterval(3_000)
        ))
    }

    @Test("direct port changes require publication")
    func changedDirectPortsRequirePublication() throws {
        let first = try state(hints: [], ipv4Port: 50_000, ipv6Port: 50_000)
        let ipv4Changed = try state(hints: [], ipv4Port: 50_001, ipv6Port: 50_000)
        let ipv6Changed = try state(hints: [], ipv4Port: 50_000, ipv6Port: 50_001)

        // Signed direct ports are reachability facts: a change publishes at once.
        #expect(ipv4Changed.requiresPublication(after: first, now: now))
        #expect(ipv6Changed.requiresPublication(after: first, now: now))
        #expect(!first.requiresPublication(after: first, now: now))
    }

    private func state(
        hints: [CmxIrohPathHint],
        ipv4Port: UInt16? = nil,
        ipv6Port: UInt16? = nil,
        payloadNow: Date? = nil,
        minimumPublicationSpacing: TimeInterval =
            CmxIrohRegistrationPublicationState.defaultMinimumPublicationSpacing
    ) throws -> CmxIrohRegistrationPublicationState {
        let payloadNow = payloadNow ?? now
        let payload = try CmxIrohRegistrationPayload(
            deviceID: "123e4567-e89b-12d3-a456-426614174000",
            appInstanceID: "123e4567-e89b-12d3-a456-426614174001",
            tag: "verify",
            platform: .ios,
            endpointID: String(repeating: "0", count: 64),
            identityGeneration: 1,
            pairingEnabled: false,
            capabilities: [],
            pathHints: hints,
            directPorts: ipv4Port == nil && ipv6Port == nil
                ? nil
                : try CmxIrohDirectPorts(ipv4: ipv4Port, ipv6: ipv6Port),
            now: payloadNow
        )
        return CmxIrohRegistrationPublicationState(
            payload: payload,
            now: payloadNow,
            minimumPublicationSpacing: minimumPublicationSpacing
        )
    }

    private func directHint(_ value: String) throws -> CmxIrohPathHint {
        try CmxIrohPathHint(
            kind: .directAddress,
            value: value,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        )
    }

    private func hint(
        _ value: String,
        observedAt: Date? = nil,
        expiresAt: Date? = nil
    ) throws -> CmxIrohPathHint {
        try CmxIrohPathHint(
            kind: .relayURL,
            value: value,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: observedAt ?? now,
            expiresAt: expiresAt ?? now.addingTimeInterval(3_600)
        )
    }
}
