import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextSettings
import Observation

/// The footer's Spaces button keeps the default-off switcher discoverable. Its press is routed by the App to the
/// existing `sidebar.spaces.show` / `sidebar.spaces.hide` actions, while its state follows the settings snapshot.
extension SidebarView {
    /// Applies the current Spaces setting to the button's tint and accessibility state.
    func applySpaces() {
        spacesButton.tintOverride = spacesShown ? Palette.textSecondary : Palette.textTertiary
        spacesButton.themedToolTip = spacesShown ? Strings.hideSpaces : Strings.showSpaces
        spacesButton.setAccessibilityValue(spacesShown ? "1" : "0")
        spacesButton.setAccessibilityHelp(spacesButton.themedToolTip)
    }

    /// Binds the footer button to `sidebar.showSpaces`. The App supplies the action callback so settings writes use
    /// the same registry path as context menus and the command palette.
    public func bindSpaces(settings: @escaping @MainActor () -> SettingsController?, toggle: @escaping @MainActor () -> Void) {
        let state: @MainActor () -> Bool = { settings()?.snapshot.sidebarSections.showSpaces ?? true }
        spacesShown = state()
        onSpacesToggle = toggle
        Task { [weak self] in
            for await next in ObservationStream(state) {
                guard let self else { return }
                if spacesShown != next { spacesShown = next }
            }
        }
    }
}
