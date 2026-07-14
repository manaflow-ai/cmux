import CmuxSettings
import SwiftUI

/// Settings for the tmux-style leader prefix, its timeout, and sub-key bindings.
@MainActor
public struct LeaderKeySection: View {
    @State private var enabledModel: DefaultsValueModel<Bool>
    @State private var timeoutModel: DefaultsValueModel<Double>
    @State private var workspaceTagsModel: DefaultsValueModel<Bool>
    @State private var actionModels: [LeaderKeyAction: DefaultsValueModel<String>]

    /// Creates the Leader Key settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: Store used for every leader setting mutation.
    ///   - catalog: Catalog containing the leader master settings.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabledModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.leaderKeyEnabled))
        _timeoutModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.leaderKeyTimeout))
        _workspaceTagsModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.workspaceTagsEnabled))
        _actionModels = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: LeaderKeyAction.configurableActions.map { action in
                    (action, DefaultsValueModel(store: defaultsStore, key: action.settingsKey))
                }
            )
        )
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.leaderKey", defaultValue: "Leader Key"),
                section: .leaderKey
            )
            .accessibilityIdentifier("SettingsLeaderKeySection")

            SettingsCard {
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    searchAnchorID: "setting:leaderKey:enabled",
                    String(localized: "settings.leaderKey.enabled", defaultValue: "Enable Leader Key"),
                    subtitle: enabledModel.current
                        ? String(localized: "settings.leaderKey.enabled.subtitleOn", defaultValue: "Press the leader key prefix, then a sub-key to trigger an action.")
                        : String(localized: "settings.leaderKey.enabled.subtitleOff", defaultValue: "Leader key is disabled. The prefix key will pass through to the terminal.")
                ) {
                    Toggle(
                        String(localized: "settings.leaderKey.enabled", defaultValue: "Enable Leader Key"),
                        isOn: Binding(
                            get: { enabledModel.current },
                            set: { enabledModel.set($0) }
                        )
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }

                if enabledModel.current {
                    SettingsCardDivider()
                    SettingsCardRow(
                        configurationReview: .settingsOnly,
                        searchAnchorID: "setting:leaderKey:timeout",
                        String(localized: "settings.leaderKey.timeout", defaultValue: "Timeout"),
                        subtitle: String(localized: "settings.leaderKey.timeout.subtitle", defaultValue: "Seconds to wait for the sub-key before cancelling leader mode.")
                    ) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { timeoutModel.current },
                                    set: { timeoutModel.set($0) }
                                ),
                                in: 0.2...3.0,
                                step: 0.1
                            )
                            .frame(width: 120)
                            Text(
                                String(
                                    format: String(localized: "settings.leaderKey.timeout.value", defaultValue: "%.1fs"),
                                    timeoutModel.current
                                )
                            )
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        }
                    }

                    ForEach(LeaderKeyAction.configurableActions) { action in
                        SettingsCardDivider()
                        if let model = actionModels[action] {
                            LeaderKeyBindingRow(action: action, model: model)
                        }
                    }
                }
            }
            .settingsSearchAnchors([
                "setting:leaderKey:enabled",
                "setting:leaderKey:timeout",
                "setting:leaderKey:bindings",
            ])

            SettingsCard {
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    searchAnchorID: "setting:leaderKey:workspace-tags",
                    String(localized: "settings.app.workspaceTags", defaultValue: "Workspace Tags"),
                    subtitle: workspaceTagsModel.current
                        ? String(localized: "settings.app.workspaceTags.subtitleOn", defaultValue: "Workspace tags are shown as [tag] prefix in the workspace switcher and tab bar.")
                        : String(localized: "settings.app.workspaceTags.subtitleOff", defaultValue: "Workspace tag display and assignment are disabled.")
                ) {
                    Toggle(
                        String(localized: "settings.app.workspaceTags", defaultValue: "Workspace Tags"),
                        isOn: Binding(
                            get: { workspaceTagsModel.current },
                            set: { workspaceTagsModel.set($0) }
                        )
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
            .settingsSearchAnchors(["setting:leaderKey:workspace-tags"])
        }
        .task {
            enabledModel.startObserving()
            timeoutModel.startObserving()
            workspaceTagsModel.startObserving()
            for model in actionModels.values {
                model.startObserving()
            }
        }
    }
}
