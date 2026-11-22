import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// `debug.key` emulates `NSApplication.sendEvent` (nxdog46 preflight): a key
/// the dispatcher decided, here a user Ghostty keybind (`cmd+t=new_split:right`)
/// it delivered to the terminal, must not run the main menu's Cmd-T (New Tab)
/// when the terminal's `performKeyEquivalent` asks the menu first. AppKit's
/// own dispatch has that key as `NSApp.currentEvent`; `debug.key` does not.
@MainActor
struct DebugKeyMenuGateTests {
    @Test func aDecidedSyntheticKeyRunsNoMenuItem() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router = try #require(services.keyRouter)
        let event = try KeyInterceptionTests.key("t", keyCode: 17, [.command])
        router.decided.add(event)
        #expect(router.dispatchingSynthetic(event) { router.allowsMenuKeyEquivalent("newTab.sameKind") } == false)
    }

    /// Outside that dispatch the gate is unchanged: an undecided key follows the tier rule.
    @Test func anUndecidedKeyFollowsTheTierRule() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router = try #require(services.keyRouter)
        let event = try KeyInterceptionTests.key("t", keyCode: 17, [.command])
        #expect(router.dispatchingSynthetic(event) { router.allowsMenuKeyEquivalent("newTab.sameKind") })
    }
}
