import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Beta Features** section — a warning note followed by the experimental
/// toggles. Each toggle gates an unstable feature that is off by default.
@MainActor
public struct BetaFeaturesSection: View {
    @State private var feed: DefaultsValueModel<Bool>
    @State private var conversationSidebar: DefaultsValueModel<Bool>
    @State private var cloudMachines: DefaultsValueModel<Bool>
    @State private var extensions: DefaultsValueModel<Bool>
    @State private var customSidebars: DefaultsValueModel<Bool>
    @State private var remoteTmux: DefaultsValueModel<Bool>
    @State private var predictedEcho: DefaultsValueModel<Bool>
    @State private var workspaceTodoControls: DefaultsValueModel<Bool>
    @State private var workspaceTodosChecklistStyle: DefaultsValueModel<WorkspaceTodoChecklistStyle>
    /// `DisableCloud` (MDM). The opt-in is meaningless while an administrator
    /// forces Cloud off, so the row says so and locks the toggle; re-read on
    /// ``ManagedDevicePolicy/changeSignals(notificationCenter:)``.
    @State private var cloudMachinesManagedByPolicy = ManagedDevicePolicy().isEnforced(.disableCloud)
    /// `DisableCustomSidebars` (MDM): same treatment for the interpreted
    /// custom sidebars opt-in.
    @State private var customSidebarsManagedByPolicy = ManagedDevicePolicy().isEnforced(.disableCustomSidebars)

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _feed = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.rightSidebarFeed))
        _conversationSidebar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.conversationSidebar))
        _cloudMachines = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.cloudMachines))
        _extensions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.extensions))
        _customSidebars = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.customSidebars))
        _remoteTmux = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.remoteTmux))
        _predictedEcho = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.predictedEcho))
        _workspaceTodoControls = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.workspaceTodoControls))
        _workspaceTodosChecklistStyle = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.workspaceTodosChecklistStyle))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features"), section: .betaFeatures)
            SettingsCard {
                BetaFeaturesWarningNote(
                    String(localized: "settings.betaFeatures.warning", defaultValue: "These features are experimental and may change or break. Enable them only when you are testing them.")
                )
                SettingsCardDivider()
                feedRow
                SettingsCardDivider()
                conversationSidebarRow
                SettingsCardDivider()
                cloudMachinesRow
                SettingsCardDivider()
                extensionsRow
                SettingsCardDivider()
                customSidebarsRow
                SettingsCardDivider()
                remoteTmuxRow
                SettingsCardDivider()
                predictedEchoRow
                SettingsCardDivider()
                workspaceTodoControlsRow
                SettingsCardDivider()
                workspaceTodosChecklistStyleRow
            }
        }
        .task { startObservingSettings() }
        .task {
            for await _ in ManagedDevicePolicy.changeSignals() {
                let policy = ManagedDevicePolicy()
                cloudMachinesManagedByPolicy = policy.isEnforced(.disableCloud)
                customSidebarsManagedByPolicy = policy.isEnforced(.disableCustomSidebars)
            }
        }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            feed,
            conversationSidebar,
            cloudMachines,
            extensions,
            customSidebars,
            remoteTmux,
            predictedEcho,
            workspaceTodoControls,
            workspaceTodosChecklistStyle,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var conversationSidebarRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.beta.conversations.enabled"),
            searchAnchorID: "setting:betaFeatures:conversationSidebar",
            String(localized: "settings.betaFeatures.conversationSidebar", defaultValue: "Conversation Sidebar"),
            subtitle: conversationSidebar.current
                ? String(localized: "settings.betaFeatures.conversationSidebar.subtitleOn", defaultValue: "Shows Conversations in the left sidebar picker.")
                : String(localized: "settings.betaFeatures.conversationSidebar.subtitleOff", defaultValue: "Hides Conversations while preserving existing agent sessions.")
        ) {
            Toggle("", isOn: Binding(get: { conversationSidebar.current }, set: { conversationSidebar.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaConversationSidebarToggle")
        }
    }

    @ViewBuilder
    private var workspaceTodoControlsRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.beta.workspaceTodos.controls.enabled"),
            searchAnchorID: "setting:betaFeatures:workspace-todo-controls",
            String(localized: "settings.betaFeatures.workspaceTodoControls", defaultValue: "Workspace Todo Controls"),
            subtitle: String(localized: "settings.betaFeatures.workspaceTodoControls.subtitle", defaultValue: "Shows Add Checklist Item and status controls on workspaces. A remote rollout can turn them on even while this is off.")
        ) {
            Toggle("", isOn: Binding(get: { workspaceTodoControls.current }, set: { workspaceTodoControls.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaWorkspaceTodoControlsToggle")
        }
    }

    @ViewBuilder
    private var workspaceTodosChecklistStyleRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.beta.workspaceTodos.checklistStyle"),
            searchAnchorID: "setting:betaFeatures:workspace-todos-checklist-style",
            String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle", defaultValue: "Checklist Style"),
            subtitle: String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.subtitle", defaultValue: "Choose whether clicking a workspace checklist opens a popover or expands it under the row."),
            controlWidth: 196
        ) {
            Picker(String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle", defaultValue: "Checklist Style"), selection: Binding(
                get: { workspaceTodosChecklistStyle.current },
                set: { workspaceTodosChecklistStyle.set($0) }
            )) {
                Text(String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.popover", defaultValue: "Popover")).tag(WorkspaceTodoChecklistStyle.popover)
                Text(String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.inline", defaultValue: "Inline")).tag(WorkspaceTodoChecklistStyle.inline)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("SettingsBetaWorkspaceTodosChecklistStylePicker")
        }
    }

    @ViewBuilder
    private var feedRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:feed",
            String(localized: "settings.betaFeatures.feed", defaultValue: "Feed"),
            subtitle: String(localized: "settings.betaFeatures.feed.subtitle", defaultValue: "Adds Feed to the right sidebar for answering agent requests.")
        ) {
            Toggle("", isOn: Binding(get: { feed.current }, set: { feed.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaFeedToggle")
        }
    }

    @ViewBuilder
    private var cloudMachinesRow: some View {
        SettingsCardRow(
            configurationReview: .json("cloud.beta.machines.enabled"),
            searchAnchorID: "setting:betaFeatures:cloudMachines",
            String(localized: "settings.betaFeatures.cloudMachines", defaultValue: "Cloud Machines"),
            subtitle: cloudMachinesManagedByPolicy
                ? String(localized: "settings.managedByOrganization", defaultValue: "Managed by your organization")
                : String(localized: "settings.betaFeatures.cloudMachines.subtitle", defaultValue: "Adds Cloud Machines to the right sidebar, Settings, the command palette, and the new workspace menu. Cloud Machines also require a remote rollout; with this off, the Cloud tunnel and fleet polling stay off.")
        ) {
            Toggle("", isOn: Binding(get: { cloudMachines.current && !cloudMachinesManagedByPolicy }, set: {
                CloudMachinesBetaSettingAction(model: cloudMachines).setEnabled($0)
            }))
                .labelsHidden()
                .controlSize(.small)
                .disabled(cloudMachinesManagedByPolicy)
                .accessibilityIdentifier("SettingsBetaCloudMachinesToggle")
        }
    }

    @ViewBuilder
    private var extensionsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:extensions",
            String(localized: "settings.betaFeatures.extensions", defaultValue: "Extensions"),
            subtitle: String(localized: "settings.betaFeatures.extensions.subtitle", defaultValue: "Adds the extensions button and lets cmux install and run sidebar extensions.")
        ) {
            Toggle("", isOn: Binding(get: { extensions.current }, set: { extensions.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaExtensionsToggle")
        }
    }

    @ViewBuilder
    private var customSidebarsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:customSidebars",
            String(localized: "settings.betaFeatures.customSidebars", defaultValue: "Custom Sidebars"),
            subtitle: customSidebarsManagedByPolicy
                ? String(localized: "settings.managedByOrganization", defaultValue: "Managed by your organization")
                : String(localized: "settings.betaFeatures.customSidebars.subtitle", defaultValue: "Adds sidebars from ~/.config/cmux/sidebars to the sidebar picker.")
        ) {
            Toggle("", isOn: Binding(get: { customSidebars.current && !customSidebarsManagedByPolicy }, set: { customSidebars.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .disabled(customSidebarsManagedByPolicy)
                .accessibilityIdentifier("SettingsBetaCustomSidebarsToggle")
        }
    }

    @ViewBuilder
    private var predictedEchoRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:predictedEcho",
            String(localized: "settings.betaFeatures.predictedEcho", defaultValue: "Predictive local echo"),
            subtitle: String(localized: "settings.betaFeatures.predictedEcho.subtitle", defaultValue: "Shows typed characters right away on slow remote connections. They stay underlined until the remote host confirms them. Password prompts and full-screen apps are excluded.")
        ) {
            Toggle("", isOn: Binding(get: { predictedEcho.current }, set: { predictedEcho.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaPredictedEchoToggle")
        }
    }

    @ViewBuilder
    private var remoteTmuxRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:remoteTmux",
            String(localized: "settings.betaFeatures.remoteTmux", defaultValue: "Remote tmux"),
            subtitle: String(localized: "settings.betaFeatures.remoteTmux.subtitle", defaultValue: "Shows tmux sessions on remote hosts as workspaces in the sidebar. The sessions keep running after cmux quits.")
        ) {
            Toggle("", isOn: Binding(get: { remoteTmux.current }, set: { remoteTmux.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaRemoteTmuxToggle")
        }
    }

}

/// Small warning callout with a yellow triangle, used at the top of
/// the Beta Features card to remind users the toggles below are
/// unstable. Mirrors the legacy `BetaFeaturesWarningNote`.
@MainActor
private struct BetaFeaturesWarningNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text(text)
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
