import CmuxSettings
import SwiftUI

/// **Pane Tab Bar** section for configuring pane tab bar buttons and the More menu.
@MainActor
public struct PaneTabBarSection: View {
    private let jsonStore: JSONConfigStore
    private let hostActions: SettingsHostActions
    private let homeDirectoryPath: String

    /// Creates the Pane Tab Bar settings section.
    ///
    /// - Parameters:
    ///   - jsonStore: The store backing the global cmux.json config file whose
    ///     path the section displays.
    ///   - hostActions: Host callbacks used to open the config in an external editor.
    ///   - homeDirectoryPath: The home directory prefix abbreviated to `~` in the
    ///     displayed config path. Inject a fixed path in tests.
    public init(
        jsonStore: JSONConfigStore,
        hostActions: SettingsHostActions,
        homeDirectoryPath: String = URL.homeDirectory.path
    ) {
        self.jsonStore = jsonStore
        self.hostActions = hostActions
        self.homeDirectoryPath = homeDirectoryPath
    }

    /// The Pane Tab Bar settings section content: a documentation link plus
    /// global and project cmux.json rows.
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
        let fullPath = jsonStore.fileURL.path
        if fullPath.hasPrefix(homeDirectoryPath) {
            return "~" + String(fullPath.dropFirst(homeDirectoryPath.count))
        }
        return fullPath
    }
}
