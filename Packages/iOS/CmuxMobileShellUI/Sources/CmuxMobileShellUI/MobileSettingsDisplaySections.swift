#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Independent form sections keep each settings expression small enough to type-check.
struct MobileSettingsTerminalSections: View {
    @Binding var showAltScreenNotice: Bool
    @Binding var terminalFolderTapEnabled: Bool
    @Binding var hapticFeedbackEnabled: Bool
    let showShortcuts: () -> Void

    var body: some View {
        Section(L10n.string("mobile.settings.terminal", defaultValue: "Terminal")) {
            Toggle(isOn: $showAltScreenNotice) {
                Text(L10n.string(
                    "mobile.settings.altScreenNotice",
                    defaultValue: "Full-Screen Sizing Notice"
                ))
            }
            .accessibilityIdentifier("MobileSettingsAltScreenNoticeToggle")

            Toggle(isOn: $terminalFolderTapEnabled) {
                Text(L10n.string(
                    "mobile.settings.terminalFolderTap",
                    defaultValue: "Open Folders on Tap"
                ))
            }
            .accessibilityIdentifier("MobileSettingsTerminalFolderTapToggle")

            Button {
                showShortcuts()
            } label: {
                Label(
                    L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                    systemImage: "keyboard"
                )
            }
            .accessibilityIdentifier("MobileSettingsTerminalShortcuts")
        }

        Section {
            Toggle(isOn: $hapticFeedbackEnabled) {
                Text(L10n.string(
                    "mobile.settings.hapticFeedback",
                    defaultValue: "Haptic Feedback"
                ))
            }
            .accessibilityIdentifier("MobileSettingsHapticFeedbackToggle")
        } header: {
            Text(L10n.string("mobile.settings.haptics", defaultValue: "Haptics"))
        } footer: {
            Text(L10n.string(
                "mobile.settings.hapticFeedbackFooter",
                defaultValue: "When off, cmux does not vibrate for actions, confirmations, warnings, or errors."
            ))
        }
    }
}

struct MobileSettingsDisplaySection: View {
    @Binding var showMissingFiles: Bool
    @Binding var wrapWorkspaceTitles: Bool
    @Binding var workspacePreviewLineCount: Int
    @Binding var terminalScrollbackRows: Int

    var body: some View {
        Section(L10n.string("mobile.settings.display", defaultValue: "Display")) {
            Toggle(isOn: $showMissingFiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.settings.showMissingFiles",
                        defaultValue: "Show Missing Files"
                    ))
                    Text(L10n.string(
                        "mobile.settings.showMissingFilesCaption",
                        defaultValue: "In a workspace's Files list, keep files that were deleted or moved instead of hiding them."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("MobileSettingsShowMissingFiles")

            Toggle(isOn: $wrapWorkspaceTitles) {
                Text(L10n.string("mobile.settings.wrapTitles", defaultValue: "Wrap Workspace Titles"))
            }
            .accessibilityIdentifier("MobileSettingsWrapTitles")

            Picker(selection: $workspacePreviewLineCount) {
                Text(L10n.string("mobile.settings.previewLines.one", defaultValue: "1 Line"))
                    .tag(1)
                Text(L10n.string("mobile.settings.previewLines.two", defaultValue: "2 Lines"))
                    .tag(2)
            } label: {
                Text(L10n.string("mobile.settings.previewLines", defaultValue: "Preview Lines"))
            }
            .accessibilityIdentifier("MobileSettingsPreviewLines")

            Picker(selection: $terminalScrollbackRows) {
                Text(L10n.string("mobile.settings.terminalScrollback.rows1k", defaultValue: "1,000 Rows"))
                    .tag(1000)
                Text(L10n.string("mobile.settings.terminalScrollback.rows4k", defaultValue: "4,000 Rows"))
                    .tag(4000)
                Text(L10n.string("mobile.settings.terminalScrollback.rows10k", defaultValue: "10,000 Rows"))
                    .tag(10000)
                Text(L10n.string("mobile.settings.terminalScrollback.rows20k", defaultValue: "20,000 Rows"))
                    .tag(20000)
            } label: {
                Text(L10n.string("mobile.settings.terminalScrollback", defaultValue: "Terminal Scrollback"))
            }
            .accessibilityIdentifier("MobileSettingsTerminalScrollback")
        }
    }
}
#endif
