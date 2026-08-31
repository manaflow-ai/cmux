import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

/// Presence transitions that imply registry membership changed (a Mac's clean
/// `goodbye`, an online host the list doesn't carry) trigger a throttled
/// `loadRegistryDevices()`, so a signing-out Mac leaves the tree live and a
/// signing-in Mac appears without a manual refresh.
@MainActor
@Suite struct PresenceTriggeredRegistryRefreshTests {
    @Test func goodbyeTriggersRegistryRefresh() async throws {
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = Self.store(registry: registry)

        store.applyPresenceUpdate(
            .offline(Self.instance(deviceId: "mac-x", online: false), reason: .goodbye),
            scope: Self.scope
        )

        await store.presenceRegistryRefreshTask?.value
        #expect(await registry.listCallCount == 1)
    }

    @Test func timeoutOfflineDoesNotTriggerRefresh() async throws {
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = Self.store(registry: registry)

        // An alarm-expired Mac is offline, not signed out: its registry row
        // is untouched, so there is nothing to refetch.
        store.applyPresenceUpdate(
            .offline(Self.instance(deviceId: "mac-x", online: false), reason: .timeout),
            scope: Self.scope
        )

        #expect(store.presenceRegistryRefreshTask == nil)
        #expect(await registry.listCallCount == 0)
    }

    @Test func onlineForUnknownDeviceTriggersRefresh() async throws {
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = Self.store(registry: registry)
        store.registryDevices = [
            RegistryMembershipAuthorityTests.registryDevice(id: "mac-known")
        ]

        store.applyPresenceUpdate(
            .online(Self.instance(deviceId: "mac-new")),
            scope: Self.scope
        )

        await store.presenceRegistryRefreshTask?.value
        #expect(await registry.listCallCount == 1)
    }

    @Test func onlineForKnownDeviceDoesNotTriggerRefresh() async throws {
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = Self.store(registry: registry)
        store.registryDevices = [
            RegistryMembershipAuthorityTests.registryDevice(id: "mac-known")
        ]

        // A listed Mac flapping online is presence churn, not membership
        // evidence; the heartbeat path must not fetch.
        store.applyPresenceUpdate(
            .online(Self.instance(deviceId: "mac-known")),
            scope: Self.scope
        )

        #expect(store.presenceRegistryRefreshTask == nil)
        #expect(await registry.listCallCount == 0)
    }

    @Test func iosInstanceTransitionsDoNotTriggerRefresh() async throws {
        let registry = ScriptedDeviceRegistry(outcomes: [.ok([])])
        let store = Self.store(registry: registry)

        store.applyPresenceUpdate(
            .offline(
                Self.instance(deviceId: "phone-x", platform: "ios", online: false),
                reason: .goodbye
            ),
            scope: Self.scope
        )
        store.applyPresenceUpdate(
            .online(Self.instance(deviceId: "phone-y", platform: "ios")),
            scope: Self.scope
        )

        #expect(store.presenceRegistryRefreshTask == nil)
        #expect(await registry.listCallCount == 0)
    }

    @Test func triggerBurstCoalescesIntoOneThrottledTrailingFetch() async throws {
        let registry = ScriptedDeviceRegistry(
            outcomes: [.ok([])],
            blockedCalls: [1]
        )
        let clock = ControlPoolManualClock()
        let store = Self.store(registry: registry, clock: clock)

        store.applyPresenceUpdate(
            .offline(Self.instance(deviceId: "mac-1", online: false), reason: .goodbye),
            scope: Self.scope
        )
        await registry.waitUntilCallStarted(1)
        // Triggers landing while fetch 1 is in flight must coalesce into ONE
        // trailing pass: that fetch may have read the registry before these
        // Macs' deregistrations committed, so dropping them would strand
        // stale rows, and one fetch per trigger would stampede the API.
        store.applyPresenceUpdate(
            .offline(Self.instance(deviceId: "mac-2", online: false), reason: .goodbye),
            scope: Self.scope
        )
        store.applyPresenceUpdate(
            .offline(Self.instance(deviceId: "mac-3", online: false), reason: .goodbye),
            scope: Self.scope
        )
        store.applyPresenceUpdate(
            .online(Self.instance(deviceId: "mac-4")),
            scope: Self.scope
        )
        #expect(await registry.listCallCount == 1)
        await registry.release(call: 1)

        // The trailing pass waits out the remaining throttle window on the
        // injected clock (a degenerate zero delay fetches straight away).
        _ = try await pollUntil {
            if clock.sleeperCount == 1 { return true }
            return await registry.listCallCount == 2
        }
        clock.advance(by: .seconds(
            MobilePresenceRegistryRefreshThrottle.minimumFetchInterval
        ))
        await store.presenceRegistryRefreshTask?.value
        #expect(await registry.listCallCount == 2)
    }

    private static let scope = MobileShellScopeSnapshot(
        userID: "user-1",
        teamID: "team-a",
        generation: 0
    )

    private static func store(
        registry: ScriptedDeviceRegistry,
        clock: (any Clock<Duration>)? = nil
    ) -> MobileShellComposite {
        MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            controlPlaneSchedulingClock: clock ?? (ContinuousClock() as any Clock<Duration>)
        )
    }

    private static func instance(
        deviceId: String,
        tag: String = "default",
        platform: String = "mac",
        online: Bool = true
    ) -> PresenceInstance {
        PresenceInstance(
            deviceId: deviceId,
            tag: tag,
            platform: platform,
            online: online,
            lastSeenAt: 1_000
        )
    }
}

@Suite struct MobilePresenceRegistryRefreshThrottleTests {
    @Test func firstTriggerFetchesImmediately() {
        let throttle = MobilePresenceRegistryRefreshThrottle()
        #expect(throttle.delayBeforeNextFetch(now: Date(timeIntervalSince1970: 100)) == 0)
    }

    @Test func withinWindowDelaysTheRemainder() {
        var throttle = MobilePresenceRegistryRefreshThrottle()
        throttle.noteFetchStarted(now: Date(timeIntervalSince1970: 100))
        #expect(throttle.delayBeforeNextFetch(now: Date(timeIntervalSince1970: 102)) == 3)
    }

    @Test func elapsedWindowFetchesImmediately() {
        var throttle = MobilePresenceRegistryRefreshThrottle()
        throttle.noteFetchStarted(now: Date(timeIntervalSince1970: 100))
        #expect(throttle.delayBeforeNextFetch(now: Date(timeIntervalSince1970: 105)) == 0)
    }

    @Test func rewoundClockDoesNotFreezeRefreshes() {
        var throttle = MobilePresenceRegistryRefreshThrottle()
        throttle.noteFetchStarted(now: Date(timeIntervalSince1970: 100))
        // NTP/wall-clock rewind: never wait for the clock to catch back up.
        #expect(throttle.delayBeforeNextFetch(now: Date(timeIntervalSince1970: 50)) == 0)
    }

    @Test func resetForgetsPacing() {
        var throttle = MobilePresenceRegistryRefreshThrottle()
        throttle.noteFetchStarted(now: Date(timeIntervalSince1970: 100))
        throttle.reset()
        #expect(throttle.delayBeforeNextFetch(now: Date(timeIntervalSince1970: 101)) == 0)
    }
}
