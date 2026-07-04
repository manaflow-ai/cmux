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
    @State private var extensions: DefaultsValueModel<Bool>
    @State private var customSidebars: DefaultsValueModel<Bool>
    @State private var remoteTmux: DefaultsValueModel<Bool>

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _feed = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.rightSidebarFeed))
        _dock = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.rightSidebarDock))
        _extensions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.extensions))
        _customSidebars = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.customSidebars))
        _remoteTmux = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.remoteTmux))
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
                extensionsRow
                SettingsCardDivider()
                customSidebarsRow
                SettingsCardDivider()
                remoteTmuxRow
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            feed,
            dock,
            extensions,
            customSidebars,
            remoteTmux,
        ]
        models.forEach { $0.startObserving() }
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
