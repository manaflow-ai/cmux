import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Terminal › Video Background** card — the opt-in dynamic video background
/// played muted behind terminal content: enable toggle, YouTube video/playlist
/// (or local file) source field, and the dim-opacity slider that keeps text
/// readable over the video.
@MainActor
struct TerminalVideoBackgroundCard: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var source: DefaultsValueModel<String>
    @State private var dimOpacity: DefaultsValueModel<Double>

    @State private var sourceDraft: String = ""
    @State private var sourceDraftLoaded = false
    @State private var activeDimDragValue: Double?

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundEnabled))
        _source = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundSource))
        _dimOpacity = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundDimOpacity))
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.videoBackground.enabled"),
                String(localized: "settings.terminal.videoBackground", defaultValue: "Video Background"),
                subtitle: enabled.current
                    ? String(
                        localized: "settings.terminal.videoBackground.subtitleOn",
                        defaultValue: "A muted video plays behind terminal content in every window. It never takes clicks or keystrokes, and it pauses automatically while the window is hidden."
                    )
                    : String(
                        localized: "settings.terminal.videoBackground.subtitleOff",
                        defaultValue: "Terminal windows use the regular static background."
                    )
            ) {
                Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalVideoBackgroundToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.videoBackground.source"),
                String(localized: "settings.terminal.videoBackground.source", defaultValue: "Video Source"),
                subtitle: String(
                    localized: "settings.terminal.videoBackground.source.subtitle",
                    defaultValue: "A YouTube video or playlist URL, or a local .mp4/.mov file path. Playlists loop and advance automatically. Press Return to apply."
                ),
                controlWidth: 250
            ) {
                TextField(
                    String(
                        localized: "settings.terminal.videoBackground.source.placeholder",
                        defaultValue: "https://www.youtube.com/watch?v=…"
                    ),
                    text: $sourceDraft
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(!enabled.current)
                .onSubmit { commitSourceDraft() }
                .accessibilityIdentifier("SettingsTerminalVideoBackgroundSourceField")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.videoBackground.dimOpacity"),
                String(localized: "settings.terminal.videoBackground.dimOpacity", defaultValue: "Video Dimming"),
                subtitle: String(
                    localized: "settings.terminal.videoBackground.dimOpacity.subtitle",
                    defaultValue: "Opacity of the terminal background drawn over the video. Higher keeps text more readable; 100% hides the video entirely."
                ),
                controlWidth: 250
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(get: { displayedDimOpacity }, set: { activeDimDragValue = $0 }),
                        in: VideoBackgroundSettings.minimumDimOpacity...VideoBackgroundSettings.maximumDimOpacity,
                        step: VideoBackgroundSettings.dimOpacityStep
                    ) { editing in
                        if !editing { commitDimDrag() }
                    }
                    .frame(width: 130)
                    .disabled(!enabled.current)
                    .accessibilityIdentifier("SettingsTerminalVideoBackgroundDimSlider")

                    Text(formattedDimPercent(displayedDimOpacity))
                        .cmuxFont(size: 12, weight: .medium, design: .rounded)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .task {
            startObservingSettings()
            if !sourceDraftLoaded {
                sourceDraft = source.current
                sourceDraftLoaded = true
            }
        }
        .onChange(of: source.current) { _, newValue in
            if sourceDraft != newValue {
                sourceDraft = newValue
            }
        }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [enabled, source, dimOpacity]
        models.forEach { $0.startObserving() }
    }

    private func commitSourceDraft() {
        let trimmed = sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceDraft = trimmed
        source.set(trimmed)
    }

    private var displayedDimOpacity: Double {
        activeDimDragValue ?? VideoBackgroundSettings().normalizedDimOpacity(dimOpacity.current)
    }

    private func commitDimDrag() {
        dimOpacity.set(VideoBackgroundSettings().normalizedDimOpacity(displayedDimOpacity))
        activeDimDragValue = nil
    }

    private func formattedDimPercent(_ value: Double) -> String {
        let format = String(localized: "settings.terminal.videoBackground.dimOpacity.percent", defaultValue: "%lld%%")
        return String.localizedStringWithFormat(format, Int64((value * 100).rounded()))
    }
}
