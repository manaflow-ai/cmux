import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the production driver that feeds
/// ``MultiMacWorkspaceAggregator``: ``MobileShellComposite/unifiedAggregatorTargets``.
///
/// Before the fix, the aggregator's `refresh(targets:)` was never called outside
/// tests, so the unified list only ever showed the active Mac. The targets
/// property is the seam that turns the registry + presence into the set of
/// OTHER online Macs the aggregator fetches; these tests pin its gating:
/// flag-off ⇒ empty; the active Mac and offline/unknown devices are excluded;
/// only route-bearing, Stack-auth-trusted devices contribute.
@MainActor
@Suite struct UnifiedAggregatorTargetsTests {
    private func loopbackRoute(port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback_\(port)",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
    }

    private func device(_ id: String, name: String?, port: Int?) throws -> RegistryDevice {
        RegistryDevice(
            deviceId: id,
            platform: "mac",
            displayName: name,
            lastSeenAt: Date(timeIntervalSince1970: 0),
            instances: port.map { p in
                [RegistryAppInstance(
                    tag: "default",
                    routes: [try! loopbackRoute(port: p)],
                    lastSeenAt: Date(timeIntervalSince1970: 0)
                )]
            } ?? []
        )
    }

    private func online(_ deviceId: String) -> PresenceUpdate {
        .online(PresenceInstance(
            deviceId: deviceId,
            tag: "default",
            platform: "mac",
            online: true,
            lastSeenAt: 0
        ))
    }

    private func offline(_ deviceId: String) -> PresenceUpdate {
        .offline(
            PresenceInstance(
                deviceId: deviceId,
                tag: "default",
                platform: "mac",
                online: false,
                lastSeenAt: 0
            ),
            reason: .timeout
        )
    }

    @Test func flagOffYieldsNoTargets() throws {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: false)
        store.debugSetActiveDeviceID("mac-a")
        store.debugSetRegistryDevices([try device("mac-b", name: "B", port: 56610)])
        store.debugApplyPresence(online("mac-b"))
        #expect(store.unifiedAggregatorTargets.isEmpty)
    }

    @Test func excludesActiveOfflineAndUnknownDevices() throws {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.debugSetActiveDeviceID("mac-a")
        store.debugSetRegistryDevices([
            try device("mac-a", name: "Active", port: 56611),   // active: excluded
            try device("mac-b", name: "Online B", port: 56612), // online + route: included
            try device("mac-c", name: "Offline C", port: 56613), // offline: excluded
            try device("mac-d", name: "Unknown D", port: 56614), // no presence: excluded
        ])
        store.debugApplyPresence(online("mac-a"))
        store.debugApplyPresence(online("mac-b"))
        store.debugApplyPresence(offline("mac-c"))
        // mac-d gets no presence update at all.

        let targets = store.unifiedAggregatorTargets
        #expect(targets.map(\.deviceId).sorted() == ["mac-b"])
        #expect(targets.first?.displayName == "Online B")
    }

    @Test func excludesOnlineDeviceWithNoReachableRoute() throws {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.debugSetActiveDeviceID("mac-a")
        // Online, but advertises no routes: cannot be dialed, so contributes no
        // target (and the aggregator must not be asked to fetch from it).
        store.debugSetRegistryDevices([try device("mac-b", name: "No Route", port: nil)])
        store.debugApplyPresence(online("mac-b"))
        #expect(store.unifiedAggregatorTargets.isEmpty)
    }
}
