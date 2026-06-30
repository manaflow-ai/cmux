import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

actor WorkspaceMacSelectionPairedMacStore: MobilePairedMacStoring {
    private var records: [MobilePairedMac]

    init(_ records: [MobilePairedMac]) {
        self.records = records
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        if markActive {
            records = records.map { mac in
                var copy = mac
                copy.isActive = false
                return copy
            }
        }
        if let index = records.firstIndex(where: { $0.macDeviceID == macDeviceID }) {
            records[index].displayName = displayName
            records[index].routes = routes
            records[index].lastSeenAt = now
            records[index].isActive = markActive
        } else {
            records.append(MobilePairedMac(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                createdAt: now,
                lastSeenAt: now,
                isActive: markActive,
                stackUserID: stackUserID,
                teamID: teamID
            ))
        }
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        records
            .filter { mac in
                (mac.stackUserID == nil || mac.stackUserID == stackUserID)
                    && (teamID == nil || mac.teamID == nil || mac.teamID == teamID)
            }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await loadAll(stackUserID: stackUserID, teamID: teamID).first(where: \.isActive)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        records = records.map { mac in
            var copy = mac
            copy.isActive = copy.macDeviceID == macDeviceID
            return copy
        }
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        records = records.map { mac in
            var copy = mac
            copy.isActive = false
            return copy
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
        guard let index = records.firstIndex(where: { $0.macDeviceID == macDeviceID }) else { return }
        records[index].customName = customName
        records[index].customColor = customColor
        records[index].customIcon = customIcon
        records[index].lastSeenAt = now
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        records.removeAll { $0.macDeviceID == macDeviceID }
    }

    func removeAll() async throws {
        records = []
    }
}
