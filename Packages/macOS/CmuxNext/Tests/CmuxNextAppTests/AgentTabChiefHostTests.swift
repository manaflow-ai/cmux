import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Live proof subp6: every Chief subagent tab showed "This chat isn't available": the app's
/// panes attach to the app's own acpmux, while the Chief host runs its subagents in the
/// Chief home's acpmux. A tab whose host is the Chief home (`chief:<home id>`) attaches there.
@MainActor
struct AgentTabChiefHostTests {
    static let chief = "chief:0a1b2c3d"

    private func fixture(_ tree: [String] = []) throws -> AgentTabFixture {
        let fixture = try AgentTabFixture(tree: tree)
        fixture.tabs.chiefHost = Self.chief
        fixture.tabs.chiefPaneHost = MockAgentPaneHost()
        return fixture
    }

    /// The Chief home's tab is shown, on the Chief home's acpmux, also when restored after a
    /// relaunch (the record says who owns the session).
    @Test func aChiefSubagentTabAttachesToTheChiefHomesAcpmux() throws {
        let record = AgentSessionRef(host: Self.chief, session: "s-1")
        let fixture = try fixture([AgentTabFixture.tab(60, "tab_sub", record)])
        #expect(fixture.tabs.paneHostKind(for: record) == .chief)
        #expect(fixture.tabs.view(for: "tab_sub") != nil)
    }

    /// Another Chief home's tab (another app's) and a tab of this Mac keep their hosts.
    @Test func otherHostsKeepTheirPaneHosts() throws {
        let fixture = try fixture()
        #expect(fixture.tabs.paneHostKind(for: AgentSessionRef(host: "chief:ffffffff", session: "s")) == .remote)
        #expect(fixture.tabs.paneHostKind(for: AgentSessionRef(host: AgentTabFixture.host, session: "s")) == .local)
    }

    /// The Chief host opens the tab with its home as the host; the store records it.
    @Test func openingWithTheChiefHomeRecordsIt() async throws {
        let fixture = try fixture()
        _ = try await fixture.tabs.open(in: 3, of: fixture.service, session: "s-2", linked: true, host: Self.chief).value()
        #expect(fixture.creations.last?.record.host == Self.chief)
        // A host that is not this app's Chief home is refused, never recorded.
        #expect(throws: AgentTabRefusal.self) {
            _ = try fixture.tabs.open(in: 3, of: fixture.service, session: "s-3", linked: true, host: "chief:ffffffff")
        }
    }
}
