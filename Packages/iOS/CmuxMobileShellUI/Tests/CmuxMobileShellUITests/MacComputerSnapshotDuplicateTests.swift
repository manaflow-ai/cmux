import CMUXMobileCore
@testable import CmuxMobileShellUI
import Foundation
import Testing

@Suite struct MacComputerSnapshotDuplicateTests {
    @Test func unknownPresenceDoesNotLookLikeAnOlderPairing() {
        var snapshots = [
            snapshot(title: "MacBook Pro", presence: .online),
            snapshot(title: "MacBook Pro", presence: nil),
        ]

        MacComputerSnapshot.markOlderDuplicates(&snapshots)

        #expect(snapshots[1].isOlderDuplicate == false)
    }

    @Test func confirmedOfflineDuplicateIsMarkedAsOlderPairing() {
        var snapshots = [
            snapshot(title: "MacBook Pro", presence: .online),
            snapshot(
                title: "MacBook Pro",
                presence: .offline(lastSeenAt: Date(timeIntervalSince1970: 10))
            ),
        ]

        MacComputerSnapshot.markOlderDuplicates(&snapshots)

        #expect(snapshots[1].isOlderDuplicate)
    }

    private func snapshot(
        title: String,
        presence: DeviceTreePresence?
    ) -> MacComputerSnapshot {
        MacComputerSnapshot(
            deviceId: UUID().uuidString,
            instanceTag: nil,
            title: title,
            platform: "mac",
            colorIndex: nil,
            customColor: nil,
            customIcon: nil,
            connectionStatus: nil,
            presence: presence,
            buildLabel: "Nightly",
            routeDescription: nil,
            routes: [],
            lastSeenAt: Date(timeIntervalSince1970: 0),
            workspaceCount: 0,
            aliasIDs: []
        )
    }
}
