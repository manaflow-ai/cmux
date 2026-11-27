import Testing
@testable import CmuxSettings

/// Settings must not list a shortcut whose feature the host doesn't offer,
/// such as Open Chief while Chief's release flag is off
/// (https://github.com/manaflow-ai/cmux/issues/26003).
@Suite("ShortcutAction host availability")
struct ShortcutActionHostAvailabilityTests {
    @Test func hiddenActionsLeaveTheSettingsList() {
        let all = ShortcutAction.settingsVisibleActions(hiding: [])
        #expect(all.contains(.openChief))

        let hidden = ShortcutAction.settingsVisibleActions(hiding: [.openChief])
        #expect(!hidden.contains(.openChief))
        #expect(hidden == all.filter { $0 != .openChief })
    }

    @Test func noProviderOffersEveryAction() {
        // The package's own tests never install a host provider.
        #expect(ShortcutAction.hostUnavailableActions.isEmpty)
        #expect(ShortcutAction.settingsVisibleActions == ShortcutAction.settingsVisibleActions(hiding: []))
    }
}
