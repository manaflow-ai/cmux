import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

actor PreviewPairedMacStore: MobilePairedMacStoring {
    private var mac: MobilePairedMac?

    init(activeMac: MobilePairedMac?) {
        self.mac = activeMac
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        mac = MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            createdAt: now,
            lastSeenAt: now,
            isActive: markActive,
            stackUserID: stackUserID
        )
    }

    func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        mac.map { [$0] } ?? []
    }

    func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        mac
    }

    func setActive(macDeviceID: String) async throws {}

    func remove(macDeviceID: String) async throws {
        if mac?.macDeviceID == macDeviceID {
            mac = nil
        }
    }

    func removeAll() async throws {
        mac = nil
    }
}
