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

/// The phone, the Mac and acpmux name the same modes Full access: the phone's markers are the
/// ones in cmux-tui/spec/full-access-modes.json (the Mac's FullAccessModeRuleTests checks its own).
@Suite struct PhoneFullAccessModeRuleTests {
    @Test func theMarkersMatchTheSharedSpec() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/full-access-modes.json"))
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(spec["markers"] as? [String] == ACPMode.fullAccessMarkers)
    }

    @Test func idsAreFoldedBeforeMatching() {
        for id in ["bypassPermissions", "agent-full-access", "danger-full-access", "yolo", "Auto Approve"] {
            #expect(ACPMode.isFullAccess(id), "\(id)")
        }
        for id in ["default", "agent", "ask", "read-only", "plan", "acceptEdits", "full-auto"] {
            #expect(!ACPMode.isFullAccess(id), "\(id)")
        }
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
