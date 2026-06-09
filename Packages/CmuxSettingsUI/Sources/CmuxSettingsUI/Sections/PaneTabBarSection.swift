import CmuxSettings
import SwiftUI

/// **Pane Tab Bar** section for configuring pane tab bar buttons and the More menu.
@MainActor
public struct PaneTabBarSection: View {
    private let jsonStore: JSONConfigStore
    private let hostActions: SettingsHostActions

    /// Creates a pane tab bar settings section backed by the JSON config store and host actions.
    /// - Parameters:
    ///   - jsonStore: Store that reads and writes the user's cmux JSON configuration.
    ///   - hostActions: Callbacks for opening config files and documentation from settings.
    public init(jsonStore: JSONConfigStore, hostActions: SettingsHostActions) {
        self.jsonStore = jsonStore
        self.hostActions = hostActions
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.paneTabBar", defaultValue: "Pane Tab Bar"), section: .paneTabBar)
                .accessibilityIdentifier("PaneTabBarSettingsSection")
            SettingsCard {
                documentationRow
                SettingsCardDivider()
                globalConfigRow
                SettingsCardDivider()
                projectConfigRow
            }
        }
    }

    @ViewBuilder
    private var documentationRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:paneTabBar:documentation",
            String(localized: "settings.paneTabBar.documentation", defaultValue: "Documentation"),
            subtitle: String(localized: "settings.paneTabBar.documentation.subtitle", defaultValue: "View supported buttons, More menu items, examples, and reload behavior.")
        ) {
            Link(
                String(localized: "settings.settingsJSON.docsButton", defaultValue: "Open Docs"),
                destination: URL(string: "https://cmux.com/docs/custom-commands#surface-tab-bar-buttons")!
            )
            .font(.caption)
            .accessibilityIdentifier("PaneTabBarDocsLink")
        }
    }

    @ViewBuilder
    private var globalConfigRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:paneTabBar:global-config",
            String(localized: "settings.paneTabBar.globalConfig", defaultValue: "Global cmux.json"),
            subtitle: String(localized: "settings.paneTabBar.globalConfig.subtitle", defaultValue: "Set default pane tab bar buttons for every workspace."),
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
                .accessibilityIdentifier("PaneTabBarOpenGlobalConfigButton")
            }
        }
    }

    @ViewBuilder
    private var projectConfigRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:paneTabBar:project-config",
            String(localized: "settings.paneTabBar.projectConfig", defaultValue: "Project .cmux/cmux.json"),
            subtitle: String(localized: "settings.paneTabBar.projectConfig.subtitle", defaultValue: "Put ui.surfaceTabBar.buttons in a project config to override buttons for that directory.")
        ) {
            Link(
                String(localized: "settings.settingsJSON.docsButton", defaultValue: "Open Docs"),
                destination: URL(string: "https://cmux.com/docs/custom-commands#surface-tab-bar-buttons")!
            )
            .font(.caption)
            .accessibilityIdentifier("PaneTabBarProjectConfigDocsLink")
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
