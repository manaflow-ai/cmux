import CmuxMobileShell

@MainActor
final class RecordingDeliveredNotificationClearer: DeliveredNotificationClearing {
    private(set) var clearedIDs: [[String]] = []
    private(set) var clearedOwners: [(macDeviceID: String?, instanceTag: String?)] = []
    private(set) var badgeCounts: [Int] = []
    var deliveredIDs: [String] = []

    nonisolated init() {}

    nonisolated func removeDelivered(
        ids: [String],
        macDeviceID: String?,
        instanceTag: String?
    ) async {
        await MainActor.run {
            clearedIDs.append(ids)
            clearedOwners.append((macDeviceID, instanceTag))
        }
    }

    nonisolated func deliveredIdentifiers(
        macDeviceID: String?,
        instanceTag: String?
    ) async -> [String] {
        await MainActor.run { deliveredIDs }
    }

    nonisolated func setBadgeCount(_ count: Int) {
        MainActor.assumeIsolated {
            badgeCounts.append(count)
        }
    }
}
