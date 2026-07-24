import CmuxMobileShell

@MainActor
final class RecordingDeliveredNotificationClearer: DeliveredNotificationClearing {
    private(set) var clearedIDs: [[String]] = []
    private(set) var badgeCounts: [Int] = []
    var deliveredIDs: [String] = []

    nonisolated init() {}

    nonisolated func removeDelivered(ids: [String]) async {
        await MainActor.run {
            clearedIDs.append(ids)
        }
    }

    nonisolated func deliveredIdentifiers() async -> [String] {
        await MainActor.run { deliveredIDs }
    }

    nonisolated func setBadgeCount(_ count: Int) {
        MainActor.assumeIsolated {
            badgeCounts.append(count)
        }
    }
}
