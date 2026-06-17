import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression guard for the cross-Mac activation `activeDeviceID` binding on the
/// SYNTHETIC-ticket path.
///
/// `activeDeviceID` is the linchpin of the multi-Mac scoping scheme: it selects
/// which client a scoped surface key may route to, tags every active-Mac
/// preview, and drives `selectScopedWorkspace`'s `activeDeviceID == target`
/// guard. The bug: after the heavy connect switched to Mac B, the connect path
/// derived `activeDeviceID` from `connectedMacDeviceID`, which on a `manual-…`
/// synthetic ticket (a route lacking `mobile.attach_ticket.create`) resolves to
/// the PREVIOUSLY-active Mac (or nil) because B is not yet marked active in the
/// paired-Mac store. The fix binds `activeDeviceID` to the KNOWN target device
/// id in `connectToRegistryInstance`, matching the aggregator's slice
/// attribution.
///
/// These tests drive the real connect path (no `debugSetActiveDeviceID`), with a
/// host router whose `mobile.attach_ticket.create` fails method-not-found so the
/// connect mints a synthetic `manual-…` ticket exactly as a route without that
/// RPC does in production.
@MainActor
@Suite struct CrossMacActivationBindingTests {
    private func loopbackRoute(port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback_\(port)",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
    }

    private func onlineUpdate(deviceId: String) -> PresenceUpdate {
        .online(PresenceInstance(
            deviceId: deviceId,
            tag: "default",
            platform: "mac",
            online: true,
            lastSeenAt: 0
        ))
    }

    private func registryDeviceB(port: Int) throws -> RegistryDevice {
        RegistryDevice(
            deviceId: "mac-b",
            platform: "mac",
            displayName: "Mac B",
            lastSeenAt: Date(timeIntervalSince1970: 0),
            instances: [
                RegistryAppInstance(
                    tag: "default",
                    routes: [try loopbackRoute(port: port)],
                    lastSeenAt: Date(timeIntervalSince1970: 0)
                )
            ]
        )
    }

    /// After activating Mac B over a synthetic-ticket route, `activeDeviceID`
    /// must bind to B (the known target), not stay on the previously-active A.
    @Test func crossMacActivateBindsActiveDeviceToKnownTarget() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setFailAttachTicketCreate(true)
        let box = TransportBox()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        // The first heavy connect binds the active device to the real ticket id.
        #expect(store.activeDeviceID == "test-mac")

        store.debugSetRegistryDevices([try registryDeviceB(port: 56601)])
        store.debugApplyPresence(onlineUpdate(deviceId: "mac-b"))

        await store.activateMac(deviceId: "mac-b")

        // The heavy connection switched to B over a synthetic manual ticket
        // (no `attach_ticket.create`); the active binding must be B, not A.
        #expect(store.activeDeviceID == "mac-b")
        #expect(store.activeDeviceID != "test-mac")

        await router.releaseAllHeld()
    }

    /// `selectScopedWorkspace` on a non-active Mac's row must open the workspace
    /// (set `selectedWorkspaceID`) once the heavy connection switches — the guard
    /// `activeDeviceID == target` must pass on the synthetic path.
    @Test func selectScopedWorkspaceOnOtherMacOpensAfterSwitch() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setFailAttachTicketCreate(true)
        let box = TransportBox()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        #expect(store.activeDeviceID == "test-mac")

        store.debugSetRegistryDevices([try registryDeviceB(port: 56602)])
        store.debugApplyPresence(onlineUpdate(deviceId: "mac-b"))

        await store.selectScopedWorkspace(
            ScopedWorkspaceID(deviceId: "mac-b", workspaceID: "live-workspace")
        )

        // The guard passed (active is now B), so the bare selection landed.
        #expect(store.activeDeviceID == "mac-b")
        #expect(store.selectedWorkspaceID == "live-workspace")

        await router.releaseAllHeld()
    }
}
