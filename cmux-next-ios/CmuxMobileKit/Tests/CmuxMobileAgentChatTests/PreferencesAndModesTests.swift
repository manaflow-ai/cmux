@testable import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import Testing

@Suite struct PlanModeSwitchTests {
    @Test func claudeModesGetASwitchBackToDefault() throws {
        let modes = [ACPMode(id: "default", name: "Default"), ACPMode(id: "acceptEdits", name: "Accept Edits"),
                     ACPMode(id: "plan", name: "Plan Mode"), ACPMode(id: "bypassPermissions", name: "Bypass")]
        let plan = try #require(PlanModeSwitch(modes: modes))
        #expect(plan.mode(on: true) == "plan")
        #expect(plan.mode(on: false) == "default")
        #expect(plan.isOn(currentModeID: "plan"))
        #expect(!plan.isOn(currentModeID: "acceptEdits"))
    }

    @Test func noPlanModeOrNoModesHidesTheSwitch() {
        #expect(PlanModeSwitch(modes: []) == nil)
        #expect(PlanModeSwitch(modes: [ACPMode(id: "read-only", name: "Read Only"), ACPMode(id: "auto", name: "Auto")]) == nil)
        #expect(PlanModeSwitch(modes: [ACPMode(id: "plan", name: "Plan")]) == nil)
    }

    @Test func leavesPlanForTheFirstOtherModeWithoutADefault() throws {
        let plan = try #require(PlanModeSwitch(modes: [ACPMode(id: "plan", name: "Plan"), ACPMode(id: "auto", name: "Auto")]))
        #expect(plan.mode(on: false) == "auto")
    }
}

@MainActor
@Suite struct ComposerPreferenceTests {
    /// Settings writes through `SettingsStore`; the terminal, code cards and
    /// the composer read `CmuxMobilePreferences`: the keys and defaults must agree.
    @Test func settingsStoreAndPreferencesShareKeys() throws {
        let suite = "cmuxMobile.prefs.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(CmuxMobilePreferences.terminalFontSize(defaults) == settings.terminalFontSize)
        #expect(CmuxMobilePreferences.wrapCode(defaults) == settings.wrapCode)
        #expect(CmuxMobilePreferences.keyClicks(defaults) == settings.keyClicks)
        #expect(CmuxMobilePreferences.dismissKeyboardAfterSend(defaults) == settings.dismissKeyboardAfterSend)
        #expect(!CmuxMobilePreferences.steersFollowUps(defaults))

        settings.terminalFontSize = 17
        settings.wrapCode = true
        settings.keyClicks = false
        settings.dismissKeyboardAfterSend = false
        settings.followUp = .steer
        #expect(CmuxMobilePreferences.terminalFontSize(defaults) == 17)
        #expect(CmuxMobilePreferences.wrapCode(defaults))
        #expect(!CmuxMobilePreferences.keyClicks(defaults))
        #expect(!CmuxMobilePreferences.dismissKeyboardAfterSend(defaults))
        #expect(CmuxMobilePreferences.steersFollowUps(defaults))

        settings.terminalFontSize = 99
        #expect(CmuxMobilePreferences.terminalFontSize(defaults) == CmuxMobilePreferences.terminalFontSizes.upperBound)
    }

    @Test func liveSessionsHideCheckpoints() {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "/tmp",
                                          workspaceTitle: "w", macName: "Mac")
        #expect(!DisconnectedAgentSource(summary: summary).supportsCheckpoints)
        #if DEBUG
        #expect(MockAgentSession(summary: summary, sleep: { _ in }).supportsCheckpoints)
        #endif
    }
}
