import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func notificationSettingsRPCsRequireHostCapability() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let resolved = try await pollUntil { await router.count(of: "mobile.host.status") >= 1 }
    #expect(resolved)
    #expect(!store.supportsNotificationSettings)

    let fetched = await store.fetchNotificationPreferencesFromMac()
    let synced = await store.syncNotificationPreferencesToMac(
        MobileNotificationPreferences(
            isEnabled: true,
            forwardingMode: .always,
            hidesContent: true
        )
    )

    #expect(fetched == nil)
    #expect(synced == nil)
    #expect(await router.count(of: "notification.settings.get") == 0)
    #expect(await router.count(of: "notification.settings.set") == 0)
}
