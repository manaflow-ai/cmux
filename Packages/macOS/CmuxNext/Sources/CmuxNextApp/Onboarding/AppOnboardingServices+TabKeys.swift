import CmuxNextOnboarding
import CmuxNextSettings

/// The number keys step (D4) over cmux.json: `ShortcutDigitScheme` is the
/// one writer of the Ctrl-1…9 bindings, as Base Keymap is for presets.
extension AppOnboardingServices {
    var offersTabKeys: Bool { false }

    func currentTabKeys() async -> TabKeysChoice? { .tabs }

    func applyTabKeys(_ choice: TabKeysChoice) {}
}
