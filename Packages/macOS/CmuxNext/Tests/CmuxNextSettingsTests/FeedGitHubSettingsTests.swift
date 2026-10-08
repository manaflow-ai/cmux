import Testing
@testable import CmuxNextSettings

struct FeedGitHubSettingsTests {
    @Test func connectionIsOffByDefaultAndSchemaMatches() {
        let snapshot = parse(.object([:]))
        #expect(!snapshot.feedGitHub.enabled)
        #expect(snapshot.feedGitHub.pollIntervalSeconds == 120)
        #expect(SettingsSchema.descriptor(for: FeedGitHubSettings.enabledPath)?.defaultValue == .bool(false))
        #expect(SettingsSchema.descriptor(for: FeedGitHubSettings.pollIntervalPath)?.defaultValue == .number(120))
    }

    @Test func livePreferencesAcceptAnExplicitConnection() {
        let snapshot = parse(["feed": ["github": ["enabled": true, "pollIntervalSeconds": 300]]])
        #expect(snapshot.feedGitHub == FeedGitHubSettings(enabled: true, pollIntervalSeconds: 300))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func malformedConnectionStaysOffAndIntervalIsBounded() {
        let snapshot = parse(["feed": ["github": ["enabled": "yes", "pollIntervalSeconds": 1]]])
        #expect(!snapshot.feedGitHub.enabled)
        #expect(snapshot.feedGitHub.pollIntervalSeconds == 60)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["feed.github.enabled", "feed.github.pollIntervalSeconds"])
    }

    private func parse(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }
}
