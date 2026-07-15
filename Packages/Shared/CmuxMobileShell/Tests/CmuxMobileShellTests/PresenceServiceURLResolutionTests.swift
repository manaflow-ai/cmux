import Foundation
import Testing
@testable import CmuxMobileShell

/// The presence/backup service URL resolution drives which (possibly per-developer
/// isolated) worker a build talks to. Precedence: env → UserDefaults → Info.plist
/// → Debug default. The Info.plist path is what lets a tapped iOS device build be
/// pointed at a per-dev worker (see workers/presence/scripts/deploy-dev.sh).
struct PresenceServiceURLResolutionTests {
    private func emptyDefaults() -> UserDefaults {
        let suite = "presence-url-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func envOverrideWinsOverEverything() {
        let url = PresenceClient.resolvedServiceBaseURL(
            environment: [PresenceClient.serviceURLEnvKey: "https://env.example"],
            defaults: emptyDefaults(),
            infoPlistValue: "https://plist.example",
            isDebugBuild: true
        )
        #expect(url == "https://env.example")
    }

    @Test func defaultsOverrideWinsOverInfoPlist() {
        let d = emptyDefaults()
        d.set("https://defaults.example", forKey: PresenceClient.serviceURLDefaultsKey)
        let url = PresenceClient.resolvedServiceBaseURL(
            environment: [:],
            defaults: d,
            infoPlistValue: "https://plist.example",
            isDebugBuild: true
        )
        #expect(url == "https://defaults.example")
    }

    @Test func infoPlistUsedWhenNoEnvOrDefaults() {
        let url = PresenceClient.resolvedServiceBaseURL(
            environment: [:],
            defaults: emptyDefaults(),
            infoPlistValue: "https://cmux-presence-dev-alice.acct.workers.dev",
            isDebugBuild: true
        )
        #expect(url == "https://cmux-presence-dev-alice.acct.workers.dev")
    }

    @Test func fallsBackToBuildDefault() {
        // Debug -> dev worker; Release -> production worker (so a stable iOS app
        // subscribes to the same presence service stable Macs heartbeat to).
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [:], defaults: emptyDefaults(), infoPlistValue: nil, isDebugBuild: true
        ) == PresenceClient.debugDefaultServiceURL)
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [:], defaults: emptyDefaults(), infoPlistValue: nil, isDebugBuild: false
        ) == PresenceClient.productionServiceURL)
    }
}
