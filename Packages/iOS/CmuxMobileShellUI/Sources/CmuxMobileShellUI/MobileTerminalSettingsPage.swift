#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileTerminalSettingsPage: View {
    @Environment(MobileDisplaySettings.self) private var displaySettings

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return Form {
            Section(L10n.string("mobile.settings.terminal", defaultValue: "Terminal")) {
                NavigationLink {
                    TerminalShortcutsSettingsView(presentation: .pushed)
                } label: {
                    Label(
                        L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                        systemImage: "keyboard"
                    )
                }
                .accessibilityIdentifier("MobileSettingsTerminalShortcuts")
            }

            Section(L10n.string("mobile.settings.workspaceList", defaultValue: "Workspace List")) {
                Toggle(isOn: $displaySettings.wrapWorkspaceTitles) {
                    Text(L10n.string("mobile.settings.wrapTitles", defaultValue: "Wrap Workspace Titles"))
                }
                .accessibilityIdentifier("MobileSettingsWrapTitles")

                Picker(selection: $displaySettings.workspacePreviewLineCount) {
                    Text(L10n.string("mobile.settings.previewLines.one", defaultValue: "1 Line"))
                        .tag(1)
                    Text(L10n.string("mobile.settings.previewLines.two", defaultValue: "2 Lines"))
                        .tag(2)
                } label: {
                    Text(L10n.string("mobile.settings.previewLines", defaultValue: "Preview Lines"))
                }
                .accessibilityIdentifier("MobileSettingsPreviewLines")
            }
        }
        .navigationTitle(L10n.string("mobile.settings.terminal", defaultValue: "Terminal"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileSettingsTerminalPage")
    }
}
#endif
