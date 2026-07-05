import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    /// The prominent "+" button to the left of the terminal picker.
    ///
    /// Issue #6271: TestFlight testers expected this to add a terminal to the
    /// *current* workspace (the macOS default), not create a whole new workspace.
    /// It routes through `MobileTerminalAddAffordance.primaryNavbarButton`, whose
    /// contract a core unit test pins, so the action can't silently drift back to
    /// "new workspace". New Workspace stays reachable from the terminal picker
    /// menu.
    @ViewBuilder
    var newTerminalToolbarButton: some View {
        Button(action: performPrimaryAdd) {
            // `mobile.terminal.new` (en + ja) lives in the iOS app catalog
            // ios/cmux/Resources/Localizable.xcstrings, which `L10n.string`
            // resolves via Bundle.main — not the macOS `Resources/` catalog.
            // Reused from the existing picker-menu "New Terminal" item.
            Label(
                L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                systemImage: MobileTerminalAddAffordance.primaryNavbarButton.systemImageName
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityIdentifier("MobileTerminalNewTerminalButton")
    }

    /// Run the primary "+" affordance. Pinned to "new terminal in the current
    /// workspace" by `MobileTerminalAddAffordance.primaryNavbarButton` (issue
    /// #6271); the switch keeps the button honest if that core contract ever
    /// changes.
    func performPrimaryAdd() {
        switch MobileTerminalAddAffordance.primaryNavbarButton {
        case .newTerminalInCurrentWorkspace:
            createTerminalFromToolbar()
        case .newWorkspace:
            createWorkspaceFromToolbar()
        }
    }
}
