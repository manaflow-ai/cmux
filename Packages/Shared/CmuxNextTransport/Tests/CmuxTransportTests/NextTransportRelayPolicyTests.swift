import CmuxNextTransport
import Testing

struct NextTransportRelayPolicyTests {
    @Test func nextTransportRelayPolicyKeepsUnexpiringAndDropsStaleCache() {
        let policy = NextTransportRelayCredentialCachePolicy(reuseMarginSeconds: 30)
        let cached = [
            NextTransportCachedRelayCredential(
                relayUrl: "https://relay-a.example", token: "a", expiresAt: nil),
            NextTransportCachedRelayCredential(
                relayUrl: "https://relay-b.example", token: "b", expiresAt: 1_020),
            NextTransportCachedRelayCredential(
                relayUrl: "https://relay-c.example", token: "c", expiresAt: 1_040),
        ]
        let usable = policy.usable(cached, now: 1_000)
        #expect(usable.map(\.relayUrl) == ["https://relay-a.example", "https://relay-c.example"])
    }

    @Test func nextTransportMintRetryPolicyNeverBusyLoopsPastExpiry() {
        let policy = NextTransportMintRetryPolicy(minimumDelaySeconds: 10, expiredCadenceSeconds: 60)
        #expect(policy.retryDelay(earliestExpiry: nil, now: 1_000) == 60)
        #expect(policy.retryDelay(earliestExpiry: 900, now: 1_000) == 60)
        #expect(policy.retryDelay(earliestExpiry: 1_050, now: 1_000) == 25)
    }

    @Test func nextTransportRelayPlanWaitsOnlyWhenBrokerCanMint() {
        #expect(
            NextTransportRelayPlan.make(hasBrokerClient: false, hasUsableCache: false)
                == .directOnlyDeliberate)
        #expect(
            NextTransportRelayPlan.make(hasBrokerClient: true, hasUsableCache: false)
                == .awaitFirstMint)
        #expect(
            NextTransportRelayPlan.make(hasBrokerClient: false, hasUsableCache: true)
                == .cachedCredential)
        // A usable cache wins over minting: the bind must not await a mint.
        #expect(
            NextTransportRelayPlan.make(hasBrokerClient: true, hasUsableCache: true)
                == .cachedCredential)
    }
}
