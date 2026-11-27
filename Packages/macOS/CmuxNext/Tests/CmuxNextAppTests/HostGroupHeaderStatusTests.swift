@testable import CmuxNextSidebar
import Testing

/// A remote group's header always says how its host is (remote-groups-DESIGN.md slice 5): the
/// status text shows beside the dot for every state, Connected and Offline included. Another
/// machine's header keeps the old rule: text only for the states that need attention.
@MainActor struct HostGroupHeaderStatusTests {
    @Test func aRemoteGroupNamesEveryState() {
        let expected: [(SidebarMachine.Status, String)] = [
            (.connected, Strings.statusConnected), (.offline, Strings.statusOffline), (.connecting, Strings.statusConnecting),
            (.reconnecting, Strings.statusReconnecting), (.unreachable, Strings.statusUnreachable),
        ]
        for (status, text) in expected {
            #expect(SectionHeaderRowView.statusText(status, hostGroup: true) == text, "\(status)")
        }
    }

    @Test func anotherMachineNamesOnlyWhatNeedsAttention() {
        #expect(SectionHeaderRowView.statusText(.connected, hostGroup: false) == nil)
        #expect(SectionHeaderRowView.statusText(.offline, hostGroup: false) == nil)
        #expect(SectionHeaderRowView.statusText(.reconnecting, hostGroup: false) == Strings.statusReconnecting)
    }
}
