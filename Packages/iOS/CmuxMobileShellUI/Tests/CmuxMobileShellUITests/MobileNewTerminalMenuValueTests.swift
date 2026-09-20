import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileNewTerminalMenuValueTests {
    @Test func tapCreatesAWorkspaceWhileAMacIsConnected() {
        let value = MobileNewTerminalMenuValue(
            canCreateWorkspace: true,
            isLocalLinuxAvailable: true,
            canAddComputer: true
        )
        #expect(value.primaryAction == .createWorkspace)
        #expect(value.isEnabled)
    }

    @Test func tapOpensLocalLinuxWithoutAConnectedMac() {
        let value = MobileNewTerminalMenuValue(isLocalLinuxAvailable: true, canAddComputer: true)
        #expect(value.primaryAction == .openLocalLinux)
    }

    @Test func tapFallsBackToPairingWhenLinuxIsUnavailable() {
        #expect(MobileNewTerminalMenuValue(canAddComputer: true).primaryAction == .addComputer)
        #expect(MobileNewTerminalMenuValue().primaryAction == .none)
        #expect(!MobileNewTerminalMenuValue().isEnabled)
    }

    @Test func hostsAloneKeepTheButtonEnabled() {
        let host = MobileNewTerminalMenuValue.Host(
            id: "mac-a", macDeviceID: "mac-a", instanceTag: nil, name: "Studio", status: .offline
        )
        let value = MobileNewTerminalMenuValue(hosts: [host])
        #expect(value.primaryAction == .none)
        #expect(value.isEnabled)
    }

    @Test func hostsOrderConnectedThenOnlineThenOfflineByName() {
        let hosts = MobileNewTerminalMenuValue.hosts(from: [
            snapshot(deviceId: "mac-c", title: "Zed", presence: .offline(lastSeenAt: .distantPast)),
            snapshot(deviceId: "mac-b", title: "Air", presence: .online),
            snapshot(deviceId: "mac-a", title: "Mini", presence: .online, connectionStatus: .connected),
            snapshot(deviceId: "mac-d", title: "Book", presence: nil),
        ])
        #expect(hosts.map(\.name) == ["Mini", "Air", "Book", "Zed"])
        #expect(hosts.map(\.status) == [.connected, .online, .offline, .offline])
        #expect(hosts.first?.macDeviceID == "mac-a")
    }

    @Test func olderDuplicatePairingsAreDropped() {
        var duplicate = snapshot(deviceId: "mac-a", title: "Mini (old)", presence: .offline(lastSeenAt: .distantPast))
        duplicate.isOlderDuplicate = true
        let hosts = MobileNewTerminalMenuValue.hosts(from: [
            snapshot(deviceId: "mac-a", title: "Mini", presence: .online, instanceTag: "dev"),
            duplicate,
        ])
        #expect(hosts.map(\.name) == ["Mini"])
        #expect(hosts.first?.instanceTag == "dev")
    }

    private func snapshot(
        deviceId: String,
        title: String,
        presence: DeviceTreePresence?,
        connectionStatus: MobileMacConnectionStatus? = nil,
        instanceTag: String? = nil
    ) -> MacComputerSnapshot {
        MacComputerSnapshot(
            deviceId: deviceId,
            instanceTag: instanceTag,
            title: title,
            platform: "macos",
            colorIndex: nil,
            customColor: nil,
            customIcon: nil,
            connectionStatus: connectionStatus,
            presence: presence,
            buildLabel: nil,
            routeDescription: nil,
            lastSeenAt: .distantPast,
            workspaceCount: 0,
            aliasIDs: []
        )
    }
}
