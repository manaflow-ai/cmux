import AppKit
@testable import CmuxNextActions
import Testing

/// Specialized menu rows keep their arguments through the normal action dispatcher.
@MainActor
struct ActionMenuArgumentsTests {
    @Test func settingRowDispatchesItsKeyWithoutTakingTheGenericShortcut() throws {
        let registry = ActionRegistry.standard()
        var received: ActionInvocation?
        registry.bind("palette.toggleSetting", run: { received = $0 })
        let item = try #require(registry.makeMenuItem(for: "palette.toggleSetting",
            arguments: ["setting": .string("labs.highContrastLook")]))
        item.title = "High Contrast"
        let target = try #require(item.target as? ActionMenuTarget)
        target.performAction(item)
        #expect(received?["setting"] == .string("labs.highContrastLook"))
        #expect(received?["on"] == nil, "the handler flips the current value, not a stale menu snapshot")
        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    @Test func customizeSettingsRowKeepsItsDestinationAndLeavesCmdCommaAlone() throws {
        let registry = ActionRegistry.standard()
        let plain = try #require(registry.makeMenuItem(for: "openSettings"))
        let specialized = try #require(registry.makeMenuItem(for: "openSettings",
            arguments: ["setting": .string("card.customizeChecklist")]))
        let run = try #require(ActionRegistry.menuRun(of: specialized))
        #expect(run.id == "openSettings")
        #expect(run.arguments["setting"] == .string("card.customizeChecklist"))
        #expect(specialized.keyEquivalent.isEmpty)
        #expect(plain.keyEquivalent == ",")
    }
}
