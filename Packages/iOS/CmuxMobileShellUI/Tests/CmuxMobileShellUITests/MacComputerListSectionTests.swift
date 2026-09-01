import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct MacComputerListSectionTests {
    @Test func computersGroupUnderTheirOwnConnectionMethod() {
        let relayMac = snapshot(deviceId: "mac-relay", method: .relay)
        let tailscaleMac = snapshot(deviceId: "mac-ts", method: .tailscale)

        let sections = MacComputerListSection.sections(from: [tailscaleMac, relayMac])

        #expect(sections.map(\.method) == [.relay, .tailscale])
        #expect(sections[0].computers.map(\.deviceId) == ["mac-relay"])
        #expect(sections[1].computers.map(\.deviceId) == ["mac-ts"])
    }

    @Test func emptyMethodSectionsAreOmitted() {
        let sections = MacComputerListSection.sections(from: [
            snapshot(deviceId: "mac-1", method: .relay),
            snapshot(deviceId: "mac-2", method: .relay),
        ])

        #expect(sections.map(\.method) == [.relay])
        #expect(sections[0].computers.count == 2)
    }

    @Test func methodlessSnapshotsFallToTheRelaySection() {
        let sections = MacComputerListSection.sections(from: [
            snapshot(deviceId: "mac-1", method: nil)
        ])

        #expect(sections.map(\.method) == [.relay])
    }

    private func snapshot(
        deviceId: String,
        method: MobileConnectionMethod?
    ) -> MacComputerSnapshot {
        var snapshot = MacComputerSnapshot(
            deviceId: deviceId,
            instanceTag: nil,
            title: deviceId,
            platform: "mac",
            colorIndex: nil,
            customColor: nil,
            customIcon: nil,
            connectionStatus: nil,
            presence: nil,
            buildLabel: nil,
            routeDescription: nil,
            lastSeenAt: Date(timeIntervalSince1970: 0),
            workspaceCount: 0,
            aliasIDs: [deviceId]
        )
        snapshot.connectionMethod = method
        snapshot.routeKind = method.flatMap(\.routeKind)
        return snapshot
    }
}
