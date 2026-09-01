import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Beta Features** section — a warning note followed by the
/// experimental toggles. Each toggle gates an unstable feature that is
/// off by default.
@MainActor
public struct BetaFeaturesSection: View {
    @State private var feed: DefaultsValueModel<Bool>
    @State private var dock: DefaultsValueModel<Bool>
    @State private var cloudMachines: DefaultsValueModel<Bool>
    @State private var harbor: DefaultsValueModel<Bool>
    @State private var extensions: DefaultsValueModel<Bool>
    @State private var customSidebars: DefaultsValueModel<Bool>
    @State private var remoteTmux: DefaultsValueModel<Bool>
    @State private var tuiTerminalBackend: DefaultsValueModel<Bool>
    @State private var tuiTerminalBackendManualIO: DefaultsValueModel<Bool>
    @State private var workspaceTodoControls: DefaultsValueModel<Bool>
    @State private var workspaceTodosChecklistStyle: DefaultsValueModel<WorkspaceTodoChecklistStyle>

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _feed = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.rightSidebarFeed))
        _dock = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.rightSidebarDock))
        _cloudMachines = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.cloudMachines))
        _harbor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.rightSidebarHarbor))
        _extensions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.extensions))
        _customSidebars = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.customSidebars))
        _remoteTmux = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.remoteTmux))
        _tuiTerminalBackend = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.tuiTerminalBackend))
        _tuiTerminalBackendManualIO = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.tuiTerminalBackendManualIO))
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
                dockRow
                SettingsCardDivider()
                cloudMachinesRow
                SettingsCardDivider()
                harborRow
                SettingsCardDivider()
                extensionsRow
                SettingsCardDivider()
                customSidebarsRow
                SettingsCardDivider()
                remoteTmuxRow
                SettingsCardDivider()
                tuiTerminalBackendRow
                SettingsCardDivider()
                tuiTerminalBackendManualIORow
                SettingsCardDivider()
                workspaceTodoControlsRow
                SettingsCardDivider()
                workspaceTodosChecklistStyleRow
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            feed,
            dock,
            cloudMachines,
            harbor,
            extensions,
            customSidebars,
            remoteTmux,
            tuiTerminalBackend,
            tuiTerminalBackendManualIO,
            workspaceTodoControls,
            workspaceTodosChecklistStyle,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var workspaceTodoControlsRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.beta.workspaceTodos.controls.enabled"),
            searchAnchorID: "setting:betaFeatures:workspace-todo-controls",
            String(localized: "settings.betaFeatures.workspaceTodoControls", defaultValue: "Workspace Todo Controls"),
            subtitle: workspaceTodoControls.current
                ? String(localized: "settings.betaFeatures.workspaceTodoControls.subtitleOn", defaultValue: "Shows Add Checklist Item and workspace status controls.")
                : String(localized: "settings.betaFeatures.workspaceTodoControls.subtitleOff", defaultValue: "Keeps workspace todo summaries read-only unless remote rollout enables the controls.")
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
            subtitle: workspaceTodosChecklistStyle.current == .popover
                ? String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.subtitlePopover", defaultValue: "Clicking a row's checklist summary opens an anchored popover.")
                : String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.subtitleInline", defaultValue: "Clicking a row's checklist summary expands the items inline under the row."),
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
    private var harborRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:harbor",
            String(localized: "settings.betaFeatures.harbor", defaultValue: "Harbor"),
            subtitle: harbor.current
                ? String(localized: "settings.betaFeatures.harbor.subtitleOn", defaultValue: "Shows Harbor in the right sidebar: attachable tmux, zellij, screen, zmx, herdr, and cmux-tui sessions, local and over SSH.")
                : String(localized: "settings.betaFeatures.harbor.subtitleOff", defaultValue: "Hides Harbor from the right sidebar until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { harbor.current }, set: { harbor.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaHarborToggle")
        }
    }

    @ViewBuilder
    private var feedRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:feed",
            String(localized: "settings.betaFeatures.feed", defaultValue: "Feed"),
            subtitle: feed.current
                ? String(localized: "settings.betaFeatures.feed.subtitleOn", defaultValue: "Shows Feed in the right sidebar mode switcher for inline agent decisions.")
                : String(localized: "settings.betaFeatures.feed.subtitleOff", defaultValue: "Hides Feed from the right sidebar until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { feed.current }, set: { feed.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaFeedToggle")
        }
    }

    @ViewBuilder
    private var dockRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:dock",
            String(localized: "settings.betaFeatures.dock", defaultValue: "Dock"),
            subtitle: dock.current
                ? String(localized: "settings.betaFeatures.dock.subtitleOn", defaultValue: "Shows Dock in the right sidebar mode switcher for custom terminal controls.")
                : String(localized: "settings.betaFeatures.dock.subtitleOff", defaultValue: "Hides Dock from the right sidebar until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { dock.current }, set: { dock.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaDockToggle")
        }
    }

    @ViewBuilder
    private var cloudMachinesRow: some View {
        SettingsCardRow(
            configurationReview: .json("cloud.beta.machines.enabled"),
            searchAnchorID: "setting:betaFeatures:cloudMachines",
            String(localized: "settings.betaFeatures.cloudMachines", defaultValue: "Cloud Machines"),
            subtitle: cloudMachines.current
                ? String(localized: "settings.betaFeatures.cloudMachines.subtitleOn", defaultValue: "Shows Cloud in the right sidebar plus the Cloud Machines settings, palette commands, and new-workspace entries.")
                : String(localized: "settings.betaFeatures.cloudMachines.subtitleOff", defaultValue: "Hides every Cloud Machines surface unless remote rollout enables it.")
        ) {
            Toggle("", isOn: Binding(get: { cloudMachines.current }, set: { cloudMachines.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaCloudMachinesToggle")
        }
    }

    @ViewBuilder
    private var extensionsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:extensions",
            String(localized: "settings.betaFeatures.extensions", defaultValue: "Extensions"),
            subtitle: extensions.current
                ? String(localized: "settings.betaFeatures.extensions.subtitleOn", defaultValue: "Shows the puzzle button, the sidebar-toggle extension menu, and lets you install and host sidebar extensions.")
                : String(localized: "settings.betaFeatures.extensions.subtitleOff", defaultValue: "Hides all extension UI until you enable it here.")
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
            subtitle: customSidebars.current
                ? String(localized: "settings.betaFeatures.customSidebars.subtitleOn", defaultValue: "Lists your sidebars from ~/.config/cmux/sidebars in the sidebar picker, rendered in an isolated helper process.")
                : String(localized: "settings.betaFeatures.customSidebars.subtitleOff", defaultValue: "Hides custom sidebars from the sidebar picker until you enable them here.")
        ) {
            Toggle("", isOn: Binding(get: { customSidebars.current }, set: { customSidebars.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaCustomSidebarsToggle")
        }
    }

    @ViewBuilder
    private var remoteTmuxRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:remoteTmux",
            String(localized: "settings.betaFeatures.remoteTmux", defaultValue: "Remote tmux"),
            subtitle: remoteTmux.current
                ? String(localized: "settings.betaFeatures.remoteTmux.subtitleOn", defaultValue: "Mirrors a remote host's tmux sessions in the sidebar over ssh tmux -CC; sessions become workspaces and windows become tabs. Quitting cmux leaves the remote tmux server running.")
                : String(localized: "settings.betaFeatures.remoteTmux.subtitleOff", defaultValue: "Hides remote tmux mirroring until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { remoteTmux.current }, set: { remoteTmux.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaRemoteTmuxToggle")
        }
    }

    @ViewBuilder
    private var tuiTerminalBackendRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:tuiTerminalBackend",
            String(localized: "settings.betaFeatures.tuiTerminalBackend", defaultValue: "cmux-tui Terminal Backend"),
            subtitle: tuiTerminalBackend.current
                ? String(localized: "settings.betaFeatures.tuiTerminalBackend.subtitleOn", defaultValue: "New terminals run inside a cmux-tui daemon session and survive quitting the app. Experimental spike; remote workspaces and the dock are unaffected.")
                : String(localized: "settings.betaFeatures.tuiTerminalBackend.subtitleOff", defaultValue: "Keeps the standard local terminal spawn path until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { tuiTerminalBackend.current }, set: { tuiTerminalBackend.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaTuiTerminalBackendToggle")
        }
    }

    @ViewBuilder
    private var tuiTerminalBackendManualIORow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:betaFeatures:tuiTerminalBackendManualIO",
            String(localized: "settings.betaFeatures.tuiTerminalBackendManualIO", defaultValue: "cmux-tui Manual-IO Data Path"),
            subtitle: tuiTerminalBackendManualIO.current
                ? String(localized: "settings.betaFeatures.tuiTerminalBackendManualIO.subtitleOn", defaultValue: "Daemon-backed terminals feed bytes straight into the Ghostty surface (no attach subprocess in the pane). Requires the cmux-tui Terminal Backend toggle.")
                : String(localized: "settings.betaFeatures.tuiTerminalBackendManualIO.subtitleOff", defaultValue: "Daemon-backed terminals keep running the attach client as the surface command.")
        ) {
            Toggle("", isOn: Binding(get: { tuiTerminalBackendManualIO.current }, set: { tuiTerminalBackendManualIO.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBetaTuiTerminalBackendManualIOToggle")
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
