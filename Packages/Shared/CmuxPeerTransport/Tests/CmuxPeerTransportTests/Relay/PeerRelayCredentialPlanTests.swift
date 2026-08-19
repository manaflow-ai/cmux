import Foundation
import Testing

@testable import CmuxPeerTransport

@Suite struct PeerRelayCredentialPlanTests {
    @Test func plansConfigsInPolicyCatalogOrder() throws {
        let signer = PeerRelayPolicySigner()
        let policy = try signer.verifiedPolicy()
        let minted = signer.mintedResponse(urls: signer.relayURLs.reversed())

        let plan = try PeerRelayCredentialPlan(
            policy: policy,
            minted: minted,
            now: signer.now,
            jitter: PeerRelayRefreshJitter { 0 }
        )

        #expect(plan.configs.map(\.url) == signer.relayURLs)
        #expect(plan.configs.allSatisfy { $0.authToken == "aaa.bbb.ccc" })
        #expect(plan.schedule.refreshAfter == signer.now.addingTimeInterval(240))
        #expect(plan.schedule.expiresAt == signer.now.addingTimeInterval(300))
    }

    @Test func fleetMismatchFailsClosed() throws {
        let signer = PeerRelayPolicySigner()
        let policy = try signer.verifiedPolicy()

        let missing = signer.mintedResponse(urls: [signer.relayURLs[0]])
        #expect(throws: PeerRelayCredentialPlanError.fleetMismatch) {
            try PeerRelayCredentialPlan(policy: policy, minted: missing, now: signer.now)
        }

        let extra = signer.mintedResponse(
            urls: signer.relayURLs + ["https://extra.relay.cmux.dev/"]
        )
        #expect(throws: PeerRelayCredentialPlanError.fleetMismatch) {
            try PeerRelayCredentialPlan(policy: policy, minted: extra, now: signer.now)
        }

        let substituted = signer.mintedResponse(
            urls: [signer.relayURLs[0], "https://capture.example.com/"]
        )
        #expect(throws: PeerRelayCredentialPlanError.fleetMismatch) {
            try PeerRelayCredentialPlan(
                policy: policy,
                minted: substituted,
                now: signer.now
            )
        }
    }

    @Test func staleOrMalformedCredentialFailsClosed() throws {
        let signer = PeerRelayPolicySigner()
        let policy = try signer.verifiedPolicy()

        // refreshAfter already in the past.
        let stale = signer.mintedResponse(expiresIn: 300, refreshIn: -1)
        #expect(throws: PeerRelayCredentialPlanError.invalidCredential) {
            try PeerRelayCredentialPlan(policy: policy, minted: stale, now: signer.now)
        }

        // Token bytes outside the JWT/RCAN shape.
        let malformedToken = signer.mintedResponse(token: "not a token!!")
        #expect(throws: PeerRelayCredentialPlanError.invalidCredential) {
            try PeerRelayCredentialPlan(
                policy: policy,
                minted: malformedToken,
                now: signer.now
            )
        }

        // Unparseable wire date.
        let badDate = PeerRelayTokenResponse(
            credentials: signer.relayURLs.map {
                PeerRelayCredential(
                    relayURL: $0,
                    token: "aaa.bbb.ccc",
                    expiresAt: "not-a-date",
                    refreshAfter: PeerRelayPolicySigner.iso(
                        signer.now.addingTimeInterval(240)
                    )
                )
            }
        )
        #expect(throws: PeerRelayCredentialPlanError.invalidCredential) {
            try PeerRelayCredentialPlan(policy: policy, minted: badDate, now: signer.now)
        }
    }

    @Test func refreshDeadlineJitterStaysInWindowAndBeforeExpiry() throws {
        let signer = PeerRelayPolicySigner()
        let policy = try signer.verifiedPolicy()
        let minted = signer.mintedResponse(expiresIn: 300, refreshIn: 240)
        let refreshAfter = signer.now.addingTimeInterval(240)

        let latest = try PeerRelayCredentialPlan(
            policy: policy,
            minted: minted,
            now: signer.now,
            jitter: PeerRelayRefreshJitter { 0 }
        )
        #expect(latest.schedule.refreshDeadline == refreshAfter)

        let earliest = try PeerRelayCredentialPlan(
            policy: policy,
            minted: minted,
            now: signer.now,
            jitter: PeerRelayRefreshJitter { 1 }
        )
        #expect(
            earliest.schedule.refreshDeadline
                == refreshAfter.addingTimeInterval(-PeerRelayRefreshJitter.window)
        )

        let sampled = try PeerRelayCredentialPlan(
            policy: policy,
            minted: minted,
            now: signer.now,
            jitter: PeerRelayRefreshJitter { 0.5 }
        )
        for plan in [latest, earliest, sampled] {
            #expect(plan.schedule.refreshDeadline >= signer.now)
            #expect(plan.schedule.refreshDeadline <= plan.schedule.refreshAfter)
            #expect(plan.schedule.refreshDeadline < plan.schedule.expiresAt)
        }
    }

    @Test func jitterClampsToNowWhenRefreshWindowIsShort() throws {
        let signer = PeerRelayPolicySigner()
        let policy = try signer.verifiedPolicy()
        let minted = signer.mintedResponse(expiresIn: 60, refreshIn: 10)

        let plan = try PeerRelayCredentialPlan(
            policy: policy,
            minted: minted,
            now: signer.now,
            jitter: PeerRelayRefreshJitter { 1 }
        )
        #expect(plan.schedule.refreshDeadline == signer.now)
        #expect(plan.schedule.refreshDeadline < plan.schedule.expiresAt)
    }

    @Test func legacyHomogeneousWireFormatDecodesAndCanonicalFormEncodes() throws {
        let signer = PeerRelayPolicySigner()
        let expiresAt = PeerRelayPolicySigner.iso(signer.now.addingTimeInterval(300))
        let refreshAfter = PeerRelayPolicySigner.iso(signer.now.addingTimeInterval(240))
        let legacy = Data(
            """
            {"token":"aaa.bbb.ccc","expires_at":"\(expiresAt)",\
            "refresh_after":"\(refreshAfter)",\
            "relay_fleet":["\(signer.relayURLs[0])","\(signer.relayURLs[1])"]}
            """.utf8
        )

        let decoded = try JSONDecoder().decode(PeerRelayTokenResponse.self, from: legacy)
        #expect(decoded.relayFleet == signer.relayURLs)
        #expect(decoded.credentials.allSatisfy { $0.token == "aaa.bbb.ccc" })

        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(object.keys) == ["relay_credentials"])
        let roundTripped = try JSONDecoder().decode(
            PeerRelayTokenResponse.self,
            from: encoded
        )
        #expect(roundTripped == decoded)
    }

    @Test func fractionalSecondWireDatesParse() throws {
        let signer = PeerRelayPolicySigner()
        let policy = try signer.verifiedPolicy()
        let minted = PeerRelayTokenResponse(
            credentials: signer.relayURLs.map {
                PeerRelayCredential(
                    relayURL: $0,
                    token: "aaa.bbb.ccc",
                    expiresAt: "2026-06-21T00:05:00.500Z",
                    refreshAfter: "2026-06-21T00:04:00.250Z"
                )
            }
        )

        // signer.now is 2026-06-21T00:00:00Z.
        let plan = try PeerRelayCredentialPlan(
            policy: policy,
            minted: minted,
            now: signer.now,
            jitter: PeerRelayRefreshJitter { 0 }
        )
        #expect(plan.configs.count == 2)
        #expect(plan.schedule.expiresAt > plan.schedule.refreshAfter)
    }

    @Test func credentialDescriptionsRedactTokens() throws {
        let signer = PeerRelayPolicySigner()
        let credential = PeerRelayCredential(
            relayURL: signer.relayURLs[0],
            token: "secret.relay.jwt",
            expiresAt: PeerRelayPolicySigner.iso(signer.now.addingTimeInterval(300)),
            refreshAfter: PeerRelayPolicySigner.iso(signer.now.addingTimeInterval(240))
        )
        #expect(!credential.description.contains("secret.relay.jwt"))

        let config = try PeerRelayConfig(
            url: signer.relayURLs[0],
            authToken: "secret.relay.jwt",
            expiresAt: signer.now.addingTimeInterval(300),
            refreshAfter: signer.now.addingTimeInterval(240),
            now: signer.now
        )
        #expect(!config.description.contains("secret.relay.jwt"))
    }
}
