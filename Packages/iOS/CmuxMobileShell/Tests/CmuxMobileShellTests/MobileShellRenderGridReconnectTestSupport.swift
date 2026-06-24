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
        teamID: String?,
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
            stackUserID: stackUserID,
            teamID: teamID
        )
        if markActive {
            activeMacID = macDeviceID
        }
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        macsByID.values
            .filter { isVisible($0, stackUserID: stackUserID, teamID: teamID) }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        guard let activeMacID,
              let mac = macsByID[activeMacID],
              isVisible(mac, stackUserID: stackUserID, teamID: teamID) else {
            return nil
        }
        return mac
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        activeMacID = macDeviceID
        for id in macsByID.keys {
            guard let mac = macsByID[id],
                  isVisible(mac, stackUserID: stackUserID, teamID: teamID) else {
                continue
            }
            macsByID[id]?.isActive = id == macDeviceID
        }
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        if let activeMacID,
           let mac = macsByID[activeMacID],
           isVisible(mac, stackUserID: stackUserID, teamID: teamID) {
            self.activeMacID = nil
        }
        for id in macsByID.keys {
            guard let mac = macsByID[id],
                  isVisible(mac, stackUserID: stackUserID, teamID: teamID) else {
                continue
            }
            macsByID[id]?.isActive = false
        }
    }

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard var mac = macsByID[macDeviceID],
              isVisible(mac, stackUserID: stackUserID, teamID: teamID) else {
            return
        }
        mac.customName = customName
        mac.customColor = customColor
        mac.customIcon = customIcon
        mac.lastSeenAt = now
        macsByID[macDeviceID] = mac
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        if let mac = macsByID[macDeviceID],
           isVisible(mac, stackUserID: stackUserID, teamID: teamID) {
            macsByID.removeValue(forKey: macDeviceID)
            if activeMacID == macDeviceID {
                activeMacID = nil
            }
        }
    }

    func removeAll() async throws {
        macsByID.removeAll()
        activeMacID = nil
    }

    private func isVisible(
        _ mac: MobilePairedMac,
        stackUserID: String?,
        teamID: String?
    ) -> Bool {
        if let stackUserID, mac.stackUserID != stackUserID {
            return false
        }
        guard let teamID else {
            return true
        }
        return mac.teamID == nil || mac.teamID == teamID
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
        teamID: nil,
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
