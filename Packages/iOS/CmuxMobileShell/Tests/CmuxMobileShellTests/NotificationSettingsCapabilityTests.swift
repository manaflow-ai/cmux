import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
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

@MainActor
@Test func notificationSettingsSyncStopsWhenMacSwitchesDuringCapabilityProbe() async throws {
    let clock = TestClock()
    let oldRouter = LivenessHostRouter()
    let oldBox = TransportBox()
    await oldRouter.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
        "notification.settings.v1",
    ])
    await oldRouter.holdHostStatusRequest(number: 2)
    let store = try await makeConnectedStore(router: oldRouter, box: oldBox, clock: clock)
    let initialProbeResolved = try await pollUntil {
        await oldRouter.count(of: "mobile.host.status") >= 1
    }
    #expect(initialProbeResolved)
    store.supportedHostCapabilities = []

    let syncTask = Task { @MainActor in
        await store.syncNotificationPreferencesToMac(
            MobileNotificationPreferences(
                isEnabled: true,
                forwardingMode: .always,
                hidesContent: true
            )
        )
    }
    let staleProbeStarted = try await pollUntil {
        await oldRouter.count(of: "mobile.host.status") >= 2
    }
    #expect(staleProbeStarted)

    let newRouter = LivenessHostRouter()
    let newBox = TransportBox()
    try installNotificationSettingsRemoteClient(on: store, router: newRouter, box: newBox, clock: clock)
    store.supportedHostCapabilities = ["notification.settings.v1"]
    await oldRouter.releaseAllHeld()

    let result = await syncTask.value
    #expect(result == nil)
    #expect(await oldRouter.count(of: "notification.settings.set") == 0)
    #expect(await newRouter.count(of: "notification.settings.set") == 0)
}

@MainActor
@Test func notificationSettingsFetchStopsWhenMacSwitchesDuringCapabilityProbe() async throws {
    let clock = TestClock()
    let oldRouter = LivenessHostRouter()
    let oldBox = TransportBox()
    await oldRouter.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
        "notification.settings.v1",
    ])
    await oldRouter.holdHostStatusRequest(number: 2)
    let store = try await makeConnectedStore(router: oldRouter, box: oldBox, clock: clock)
    let initialProbeResolved = try await pollUntil {
        await oldRouter.count(of: "mobile.host.status") >= 1
    }
    #expect(initialProbeResolved)
    store.supportedHostCapabilities = []

    let fetchTask = Task { @MainActor in
        await store.fetchNotificationPreferencesFromMac()
    }
    let staleProbeStarted = try await pollUntil {
        await oldRouter.count(of: "mobile.host.status") >= 2
    }
    #expect(staleProbeStarted)

    let newRouter = LivenessHostRouter()
    let newBox = TransportBox()
    try installNotificationSettingsRemoteClient(on: store, router: newRouter, box: newBox, clock: clock)
    store.supportedHostCapabilities = ["notification.settings.v1"]
    await oldRouter.releaseAllHeld()

    let result = await fetchTask.value
    #expect(result == nil)
    #expect(await oldRouter.count(of: "notification.settings.get") == 0)
    #expect(await newRouter.count(of: "notification.settings.get") == 0)
}

@MainActor
private func installNotificationSettingsRemoteClient(
    on store: MobileShellComposite,
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock
) throws {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let route = try CmxAttachRoute(
        id: "debug_loopback_notification_settings",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56587)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac-2",
        macDisplayName: "Test Mac 2",
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: [route],
        expiresAt: clock.now.addingTimeInterval(3600)
    )
    store.remoteClient = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
}
