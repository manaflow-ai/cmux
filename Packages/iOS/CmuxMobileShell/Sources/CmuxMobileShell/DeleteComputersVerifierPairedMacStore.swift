#if DEBUG
import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

actor DeleteComputersVerifierPairedMacStore: MobilePairedMacStoring {
    private var records: [MobilePairedMac]

    init(records: [MobilePairedMac]) {
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
            records[index].stackUserID = stackUserID
            records[index].teamID = teamID
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
        records.filter { mac in
            mac.stackUserID == stackUserID && mac.teamID == teamID
        }
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        records.first { mac in
            mac.isActive && mac.stackUserID == stackUserID && mac.teamID == teamID
        }
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        records = records.map { mac in
            var copy = mac
            if copy.stackUserID == stackUserID && copy.teamID == teamID {
                copy.isActive = copy.macDeviceID == macDeviceID
            }
            return copy
        }
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        records = records.map { mac in
            var copy = mac
            if copy.stackUserID == stackUserID && copy.teamID == teamID {
                copy.isActive = false
            }
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
        guard let index = records.firstIndex(where: {
            $0.macDeviceID == macDeviceID && $0.stackUserID == stackUserID && $0.teamID == teamID
        }) else { return }
        records[index].customName = customName
        records[index].customColor = customColor
        records[index].customIcon = customIcon
        records[index].lastSeenAt = now
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        records.removeAll {
            $0.macDeviceID == macDeviceID && $0.stackUserID == stackUserID && $0.teamID == teamID
        }
    }

    func removeAll() async throws {
        records.removeAll()
    }
}
#endif
