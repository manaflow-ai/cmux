import CmuxSettings
import SwiftUI

/// **cmux.json** section — mirrors the legacy in-app section: a card
/// containing the User Config File row (display path + Open button)
/// and the Documentation row (Open Docs link).
@MainActor
public struct SettingsJSONSection: View {
    private let jsonStore: JSONConfigStore
    private let hostActions: SettingsHostActions

    public init(jsonStore: JSONConfigStore, hostActions: SettingsHostActions) {
        self.jsonStore = jsonStore
        self.hostActions = hostActions
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.settingsJSON", defaultValue: "cmux.json"), section: .settingsJSON)
                .accessibilityIdentifier("SettingsJSONSection")
            SettingsCard {
                userConfigFileRow
                SettingsCardDivider()
                documentationRow
            }
        }
    }

    @ViewBuilder
    private var userConfigFileRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:settingsJSON:open-file",
            String(localized: "settings.settingsJSON.file", defaultValue: "User config file"),
            subtitle: String(localized: "settings.settingsJSON.file.subtitle", defaultValue: "Edit cmux-owned app settings, shortcuts, automation, sidebar, notifications, and browser behavior."),
            controlWidth: 330
        ) {
            HStack(spacing: 8) {
                Text(displayPath)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Button(String(localized: "settings.settingsJSON.openButton", defaultValue: "Open")) {
                    hostActions.openConfigInExternalEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsJSONOpenButton")
            }
            .accessibilityIdentifier("SettingsJSONOpenFileRowActions")
        }
    }

    @ViewBuilder
    private var documentationRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:settingsJSON:documentation",
            String(localized: "settings.settingsJSON.documentation", defaultValue: "Documentation"),
            subtitle: String(localized: "settings.settingsJSON.documentation.subtitle", defaultValue: "View supported keys, file locations, schema, and reload behavior.")
        ) {
            Link(
                String(localized: "settings.settingsJSON.docsButton", defaultValue: "Open Docs"),
                destination: URL(string: "https://cmux.com/docs/configuration#cmux-json")!
            )
            .font(.caption)
            .accessibilityIdentifier("SettingsJSONDocsLink")
        }
    }

    private var displayPath: String {
        let homePath = NSHomeDirectory()
        let fullPath = jsonStore.fileURL.path
        if fullPath.hasPrefix(homePath) {
            return "~" + String(fullPath.dropFirst(homePath.count))
        }
        return fullPath
    }
}
