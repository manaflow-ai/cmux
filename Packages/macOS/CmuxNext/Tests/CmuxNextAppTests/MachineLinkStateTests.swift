import AppKit
@testable import CmuxNextSidebar
import Foundation
import Testing

/// One machine-state word for the sidebar header and the composer strip (Leo, 2026-10-28: "you
/// just get a little green dot"): green only once the daemon finished its handshake, a spinner on
/// its way, red when down.
@MainActor @Suite(.serialized) struct MachineLinkStateTests {
    private static let all: [SidebarMachine.Status] = [
        .connected, .connecting, .reconnecting, .offline, .updateAvailable, .updateRequired, .installRequired, .installing,
        .authFailed, .unreachable, .failed, .disconnected, .paused, .pausedIdle, .pausing, .resuming, .deleting,
    ]

    @Test func everyStatusHasOneWord() {
        let expected: [SidebarMachine.Status: MachineLinkState] = [
            .connected: .connected, .updateAvailable: .connected,
            .connecting: .connecting, .reconnecting: .connecting, .installing: .connecting,
            .pausing: .connecting, .resuming: .connecting, .deleting: .connecting,
            .offline: .offline, .unreachable: .offline, .authFailed: .offline, .failed: .offline, .updateRequired: .offline,
            .paused: .paused, .pausedIdle: .paused, .installRequired: .attention, .disconnected: .attention,
        ]
        for status in Self.all { #expect(status.linkState == expected[status], "\(status)") }
    }

    /// Only a link that dropped or never came up reconnects on use; sign-in and updates wait for a person.
    @Test func onlyADroppedLinkReconnectsOnUse() {
        let reconnects = Set(Self.all.filter(MachineLinkState.reconnectsOnUse))
        #expect(reconnects == [.offline, .unreachable, .failed, .disconnected])
    }

    private static func header(_ status: SidebarMachine.Status, kind: SidebarMachine.Kind = .ssh) -> SectionHeaderRowView {
        let section = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("box"), name: "build-box", kind: kind, status: status)), nodes: [])
        let view = SectionHeaderRowView(key: .section(section.id))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        view.configure(section, row: SidebarRow(key: .section(section.id), y: 0, height: 28, section: section.id,
                                                siblingIndex: 0, isLastInGroup: true, isCollapsed: false, childCount: 0))
        return view
    }

    /// The header draws the same word: a spinner while connecting or reconnecting (never a pulsing
    /// dot), red when offline, green once connected, grey when paused.
    @Test func theHeaderDrawsTheWord() {
        #expect(Self.header(.connected).statusTone == .success)
        #expect(Self.header(.updateAvailable).statusTone == .success, "An optional update reads as connected, as in the strip")
        #expect(Self.header(.connecting).statusTone == .working)
        #expect(Self.header(.reconnecting).statusTone == .working)
        for status: SidebarMachine.Status in [.pausing, .resuming, .deleting] {
            #expect(Self.header(status, kind: .cloud).statusTone == .working)
        }
        #expect(Self.header(.offline).statusTone == .danger)
        #expect(Self.header(.unreachable).statusTone == .danger)
        #expect(Self.header(.paused, kind: .cloud).statusTone == .quiet)
        #expect(Self.header(.disconnected, kind: .cloud).statusTone == .attention)
        #expect(Self.header(.connected, kind: .local).statusTone == nil, "This Mac draws no dot while connected")
    }
}
