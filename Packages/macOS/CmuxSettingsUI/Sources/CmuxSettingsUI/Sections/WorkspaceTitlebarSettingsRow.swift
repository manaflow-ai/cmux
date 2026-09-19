import CmuxSettings
import SwiftUI

/// The title-strip preference remains stored while Minimal Mode overrides it.
struct WorkspaceTitlebarSettingsRow: View {
    @LiveSetting(\.app.workspaceTitlebarVisibility) private var showTitlebar
    @LiveSetting(\.app.presentationMode) private var presentationMode

    private var title: String {
        String(localized: "settings.app.showWorkspaceTitleBar", defaultValue: "Show Workspace Title Bar")
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("app.showWorkspaceTitleBar"),
            title,
            subtitle: String(
                localized: "settings.app.showWorkspaceTitleBar.subtitle",
                defaultValue: "Pane tabs stay visible. Minimal Mode always hides the title bar."
            )
        ) {
            Toggle(isOn: $showTitlebar) { EmptyView() }
                .labelsHidden()
                .controlSize(.small)
                .disabled(presentationMode == .minimal)
                .accessibilityIdentifier("SettingsShowWorkspaceTitleBarToggle")
                .accessibilityLabel(title)
        }
    }
}
