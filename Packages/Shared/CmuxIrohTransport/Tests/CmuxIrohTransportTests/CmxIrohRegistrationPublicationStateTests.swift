import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh registration publication state")
struct CmxIrohRegistrationPublicationStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("path addition removal and replacement require publication")
    func changedPathsRequirePublication() throws {
        let first = try state(hints: [hint("https://relay-a.example/")])

        #expect(try state(hints: []).requiresPublication(after: first, now: now))
        #expect(
            try state(hints: [
                hint("https://relay-a.example/"),
                hint("https://relay-b.example/"),
            ]).requiresPublication(after: first, now: now)
        )
        #expect(
            try state(hints: [hint("https://relay-b.example/")])
                .requiresPublication(after: first, now: now)
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

        #expect(ipv4Changed.requiresPublication(after: first, now: now))
        #expect(ipv6Changed.requiresPublication(after: first, now: now))
        #expect(!first.requiresPublication(after: first, now: now))
    }

    private func state(
        hints: [CmxIrohPathHint],
        ipv4Port: UInt16? = nil,
        ipv6Port: UInt16? = nil,
        payloadNow: Date? = nil
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
        return CmxIrohRegistrationPublicationState(payload: payload, now: payloadNow)
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
