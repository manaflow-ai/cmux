@testable import CmuxNextSidebar
import Testing

/// A machine header's words (remote-groups-per-machine-DESIGN.md R1, which replaced
/// remote-groups-DESIGN.md slice 5's "every state, Connected included"): the machine's icon took the
/// status dot's place, so a connected machine says nothing and every other state says itself, for a
/// remote group and another machine alike.
@MainActor struct HostGroupHeaderStatusTests {
    @Test func aRemoteGroupNamesEveryStateButConnected() {
        let expected: [(SidebarMachine.Status, String?)] = [
            (.connected, nil), (.offline, Strings.statusOffline), (.connecting, Strings.statusConnecting),
            (.reconnecting, Strings.statusReconnecting), (.unreachable, Strings.statusUnreachable),
        ]
        for (status, text) in expected {
            #expect(SectionHeaderRowView.statusText(status, hostGroup: true) == text, "\(status)")
        }
    }

    @Test func anotherMachineFollowsTheSameRule() {
        #expect(SectionHeaderRowView.statusText(.connected, hostGroup: false) == nil)
        #expect(SectionHeaderRowView.statusText(.offline, hostGroup: false) == Strings.statusOffline)
        #expect(SectionHeaderRowView.statusText(.reconnecting, hostGroup: false) == Strings.statusReconnecting)
    }
}
