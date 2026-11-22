import Foundation
import Testing
@testable import CmuxNextBrowser

/// One owner decides whether Chromium fills saved passwords in a tab
/// (plans/cmux-next/passwords.md, slice 1): an agent-driven tab never fills;
/// a profile whose password manager is an extension, or where the person
/// turned autofill off, never fills; otherwise Chromium's default (fill).
@MainActor @Suite struct PasswordFillPolicyTests {
    @Test(arguments: [false, true], [false, true])
    func fillsOnlyWhenEveryInputAllows(agentDriven: Bool, profileAllows: Bool) {
        #expect(PasswordFillPolicy.fills(agentDriven: agentDriven, profileAllows: profileAllows) == (!agentDriven && profileAllows))
    }

    private func makeTab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "t"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    @Test func aTabFillsByDefault() {
        #expect(makeTab().passwordFills)
    }

    @Test func theProfileCanTurnFillingOffAndBackOn() {
        let tab = makeTab()
        tab.setPasswordFillAllowedByProfile(false)
        #expect(!tab.passwordFills)
        tab.setPasswordFillAllowedByProfile(true)
        #expect(tab.passwordFills)
    }

    /// The agent mark wins over the profile: an agent-driven tab never fills again.
    @Test func anAgentDrivenTabNeverFillsAgain() {
        let tab = makeTab()
        tab.markAgentDriven()
        tab.setPasswordFillAllowedByProfile(true)
        #expect(!tab.passwordFills)
    }

    @Test func otherEnginesIgnoreTheProfileSwitch() {
        let tab = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration())
        tab.setPasswordFillAllowedByProfile(false)
        #expect(!tab.isAgentDriven)
    }

    /// The switch is sent only when it changes Chromium's state.
    @Test func theSwitchIsSentOnlyOnChange() {
        var state = PasswordFillState()
        var sent = state.nextSwitchValue(agentDriven: false)
        #expect(sent == nil, "Chromium fills by default")
        var changed = state.setAllowedByProfile(false)
        #expect(changed)
        sent = state.nextSwitchValue(agentDriven: false)
        #expect(sent == 0)
        sent = state.nextSwitchValue(agentDriven: false)
        #expect(sent == nil)
        changed = state.setAllowedByProfile(true)
        #expect(changed)
        sent = state.nextSwitchValue(agentDriven: false)
        #expect(sent == 1)
        sent = state.nextSwitchValue(agentDriven: true)
        #expect(sent == 0)
        changed = state.setAllowedByProfile(true)
        #expect(!changed)
    }
}
