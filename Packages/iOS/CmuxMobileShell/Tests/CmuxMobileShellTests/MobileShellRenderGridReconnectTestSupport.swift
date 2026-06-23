import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
@testable import CmuxMobileShell

actor InMemoryPairedMacStore: MobilePairedMacStoring {
    private var macsByID: [String: MobilePairedMac] = [:]
    private var activeMacID: String?

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        let existing = macsByID[macDeviceID]
        macsByID[macDeviceID] = MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            createdAt: existing?.createdAt ?? now,
            lastSeenAt: now,
            isActive: markActive || existing?.isActive == true,
            stackUserID: stackUserID
        )
        if markActive {
            activeMacID = macDeviceID
        }
    }

    func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        macsByID.values
            .filter { stackUserID == nil || $0.stackUserID == stackUserID }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        guard let activeMacID,
              let mac = macsByID[activeMacID],
              stackUserID == nil || mac.stackUserID == stackUserID else {
            return nil
        }
        return mac
    }

    func setActive(macDeviceID: String) async throws {
        activeMacID = macDeviceID
        for id in macsByID.keys {
            macsByID[id]?.isActive = id == macDeviceID
        }
    }

    func remove(macDeviceID: String) async throws {
        macsByID.removeValue(forKey: macDeviceID)
        if activeMacID == macDeviceID {
            activeMacID = nil
        }
    }

    func removeAll() async throws {
        macsByID.removeAll()
        activeMacID = nil
    }
}

@MainActor
func makeDisconnectedStoreWithActivePairedMac(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    probeTimeoutNanoseconds: UInt64 = 200_000_000
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now },
        livenessProbeTimeoutNanoseconds: probeTimeoutNanoseconds
    )
    let pairedMacStore = InMemoryPairedMacStore()
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    try await pairedMacStore.upsert(
        macDeviceID: "test-mac",
        displayName: "Test Mac",
        routes: [route],
        markActive: true,
        stackUserID: nil,
        now: clock.now
    )
    return MobileShellComposite(
        runtime: runtime,
        isSignedIn: true,
        workspaces: PreviewMobileHost.workspaces,
        pairedMacStore: pairedMacStore,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer()
    )
}
