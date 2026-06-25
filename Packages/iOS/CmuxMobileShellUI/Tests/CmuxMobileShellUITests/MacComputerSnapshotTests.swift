@testable import CmuxMobileShellUI
import CmuxMobileShellModel
import Foundation
import Testing

@Suite struct MacComputerSnapshotTests {
    @Test func stableSortIgnoresConnectionStatusChanges() {
        let now = Date()
        let offlineAlpha = snapshot("mac-b", title: "Alpha", status: .unavailable, now: now)
        let connectedBravo = snapshot("mac-c", title: "Bravo", status: .connected, now: now)
        let reconnectingAlpha = snapshot("mac-a", title: "Alpha", status: .reconnecting, now: now)

        let sorted = MacComputerSnapshot.stableSorted([connectedBravo, offlineAlpha, reconnectingAlpha])

        #expect(sorted.map(\.deviceId) == ["mac-a", "mac-b", "mac-c"])
        #expect(sorted.map(\.title) == ["Alpha", "Alpha", "Bravo"])
    }

    private func snapshot(
        _ id: String,
        title: String,
        status: MobileMacConnectionStatus,
        now: Date
    ) -> MacComputerSnapshot {
        MacComputerSnapshot(
            deviceId: id,
            title: title,
            platform: "mac",
            colorIndex: nil,
            customColor: nil,
            customIcon: nil,
            connectionStatus: status,
            presence: nil,
            buildLabel: nil,
            routeDescription: nil,
            lastSeenAt: now,
            workspaceCount: 0
        )
    }
}
