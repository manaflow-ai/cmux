import Foundation
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct MacComputerSearchTests {
    @Test func matchesIdentityRouteBuildAndStatusFields() {
        let computer = makeComputer(
            deviceId: "mac-mini-42",
            title: "Kitchen Studio",
            connectionStatus: .connected,
            presence: .online,
            buildLabel: "DEV ioscs",
            routeDescription: "tailscale.local:17320"
        )

        #expect(computer.matchesSearchQuery("kitchen"))
        #expect(computer.matchesSearchQuery("MINI-42"))
        #expect(computer.matchesSearchQuery("ioscs"))
        #expect(computer.matchesSearchQuery("tailscale"))
        #expect(computer.matchesSearchQuery("connected"))
        #expect(computer.matchesSearchQuery("online"))
    }

    @Test func rejectsUnmatchedQueryAndTreatsBlankQueryAsVisible() {
        let computer = makeComputer(
            deviceId: "work-mac",
            title: "Desk Mac",
            connectionStatus: .unavailable,
            presence: .offline(lastSeenAt: Date(timeIntervalSince1970: 0)),
            buildLabel: nil,
            routeDescription: nil
        )

        #expect(computer.matchesSearchQuery("   "))
        #expect(!computer.matchesSearchQuery("laptop"))
    }

    private func makeComputer(
        deviceId: String,
        title: String,
        connectionStatus: MobileMacConnectionStatus?,
        presence: DeviceTreePresence?,
        buildLabel: String?,
        routeDescription: String?
    ) -> MacComputerSnapshot {
        MacComputerSnapshot(
            deviceId: deviceId,
            title: title,
            platform: "mac",
            colorIndex: 1,
            customColor: "blue",
            customIcon: "desktopcomputer",
            connectionStatus: connectionStatus,
            presence: presence,
            buildLabel: buildLabel,
            routeDescription: routeDescription,
            lastSeenAt: Date(timeIntervalSince1970: 0),
            workspaceCount: 3
        )
    }
}
