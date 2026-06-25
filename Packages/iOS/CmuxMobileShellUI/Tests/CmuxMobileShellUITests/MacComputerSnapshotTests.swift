@testable import CmuxMobileShellUI
import CmuxMobileShellModel
import Foundation
import Testing

@Suite struct MacComputerSnapshotTests {
    @Test func stableSortOrdersActiveComputersFirst() {
        let now = Date()
        let offlineAlpha = snapshot("mac-b", title: "Alpha", status: .unavailable, now: now)
        let connectedBravo = snapshot("mac-c", title: "Bravo", status: .connected, now: now)
        let reconnectingAlpha = snapshot("mac-a", title: "Alpha", status: .reconnecting, now: now)
        let connectedAlpha = snapshot("mac-d", title: "Alpha", status: .connected, now: now)

        let sorted = MacComputerSnapshot.stableSorted([
            connectedBravo,
            offlineAlpha,
            reconnectingAlpha,
            connectedAlpha,
        ])

        #expect(sorted.map(\.deviceId) == ["mac-d", "mac-c", "mac-a", "mac-b"])
        #expect(sorted.map(\.title) == ["Alpha", "Bravo", "Alpha", "Alpha"])
    }

    @Test func stableSortCollapsesDuplicateDeviceIDs() {
        let oldOffline = snapshot(
            "mac-a",
            title: "Old",
            status: .unavailable,
            now: Date(timeIntervalSince1970: 10),
            customColor: "palette:3",
            customIcon: "desktopcomputer"
        )
        let connected = snapshot(
            "mac-a",
            title: "Current",
            status: .connected,
            now: Date(timeIntervalSince1970: 20)
        )

        let sorted = MacComputerSnapshot.stableSorted([oldOffline, connected])

        #expect(sorted.count == 1)
        #expect(sorted.first?.deviceId == "mac-a")
        #expect(sorted.first?.title == "Current")
        #expect(sorted.first?.connectionStatus == .connected)
        #expect(sorted.first?.customColor == "palette:3")
        #expect(sorted.first?.customIcon == "desktopcomputer")
    }

    @Test func stableIdentitySurvivesRepresentativeDeviceIDChanges() {
        let aliases = ["mac-old", "mac-fresh"]
        let oldRepresentative = snapshot(
            "mac-old",
            title: "Desk",
            status: .connected,
            now: Date(timeIntervalSince1970: 10),
            aliasIDs: aliases
        )
        let freshRepresentative = snapshot(
            "mac-fresh",
            title: "Desk",
            status: .connected,
            now: Date(timeIntervalSince1970: 20),
            aliasIDs: Array(aliases.reversed())
        )

        #expect(oldRepresentative.id == freshRepresentative.id)
        #expect(oldRepresentative.stableIdentity == "mac-fresh|mac-old")
    }

    private func snapshot(
        _ id: String,
        title: String,
        status: MobileMacConnectionStatus,
        now: Date,
        customColor: String? = nil,
        customIcon: String? = nil,
        aliasIDs: [String]? = nil
    ) -> MacComputerSnapshot {
        MacComputerSnapshot(
            deviceId: id,
            title: title,
            platform: "mac",
            colorIndex: nil,
            customColor: customColor,
            customIcon: customIcon,
            connectionStatus: status,
            presence: nil,
            buildLabel: nil,
            routeDescription: nil,
            lastSeenAt: now,
            workspaceCount: 0,
            aliasIDs: aliasIDs ?? [id]
        )
    }
}
