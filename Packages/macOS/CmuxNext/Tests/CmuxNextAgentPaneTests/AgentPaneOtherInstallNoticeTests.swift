import Testing
@testable import CmuxNextAgentPane

/// cx-fcaq's "Approve its requests in that app" line says where to approve, so it shows only on
/// another install's daemon while the shown chat has a request waiting; a chat with nothing to
/// approve has no floating line over its transcript (Leo, 2026-11-01: "yuck more garbage").
struct AgentPaneOtherInstallNoticeTests {
    @Test func showsOnlyOnAnotherInstallWithARequestWaiting() {
        #expect(AgentPaneView.showsOtherInstallNotice(otherInstall: true, requestWaiting: true))
        #expect(!AgentPaneView.showsOtherInstallNotice(otherInstall: true, requestWaiting: false))
        #expect(!AgentPaneView.showsOtherInstallNotice(otherInstall: false, requestWaiting: true))
        #expect(!AgentPaneView.showsOtherInstallNotice(otherInstall: false, requestWaiting: false))
    }
}
