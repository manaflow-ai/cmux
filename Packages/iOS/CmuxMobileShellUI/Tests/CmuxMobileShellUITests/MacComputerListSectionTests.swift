import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct MacComputerListSectionTests {
    @Test func computersGroupUnderTheirOwnConnectionMethod() {
        let irohMac = snapshot(deviceId: "mac-iroh", method: .iroh)
        let directMac = snapshot(deviceId: "mac-direct", method: .direct)

        let sections = MacComputerListSection.sections(from: [directMac, irohMac])

        #expect(sections.map(\.method) == [.iroh, .direct])
        #expect(sections[0].computers.map(\.deviceId) == ["mac-iroh"])
        #expect(sections[1].computers.map(\.deviceId) == ["mac-direct"])
    }

    @Test func emptyMethodSectionsAreOmitted() {
        let sections = MacComputerListSection.sections(from: [
            snapshot(deviceId: "mac-1", method: .iroh),
            snapshot(deviceId: "mac-2", method: .iroh),
        ])

        #expect(sections.map(\.method) == [.iroh])
        #expect(sections[0].computers.count == 2)
    }

    @Test func methodlessSnapshotsFallToTheIrohSection() {
        let sections = MacComputerListSection.sections(from: [
            snapshot(deviceId: "mac-1", method: nil)
        ])

        #expect(sections.map(\.method) == [.iroh])
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
