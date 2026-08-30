import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Terminal › Video Background** card for configuring the shared video
/// queue, YouTube quality, audio, volume, dimming, and Ghostty transparency.
@MainActor
struct TerminalVideoBackgroundCard: View {
    private let hostActions: SettingsHostActions

    @State private var enabled: DefaultsValueModel<Bool>
    @State private var source: DefaultsValueModel<String>
    @State private var queue: DefaultsValueModel<[String]>
    @State private var quality: DefaultsValueModel<String>
    @State private var muted: DefaultsValueModel<Bool>
    @State private var volume: DefaultsValueModel<Double>
    @State private var dimOpacity: DefaultsValueModel<Double>

    @State private var sourceDraft = ""
    @State private var queueDraft = ""
    @State private var sourceDraftLoaded = false
    @State private var activeDimDragValue: Double?
    @State private var activeVolumeDragValue: Double?
    @State private var opacityStatus: VideoBackgroundGhosttyOpacityStatus
    @State private var showGhosttySetupConfirmation = false
    @State private var showGhosttySetupFailure = false
    @State private var pendingEnableAfterSetup = false
    @State private var isSettingUpGhostty = false

    init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions = NoopSettingsHostActions()
    ) {
        self.hostActions = hostActions
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundEnabled))
        _source = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundSource))
        _queue = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundQueue))
        _quality = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundQuality))
        _muted = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundMuted))
        _volume = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundVolume))
        _dimOpacity = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.videoBackgroundDimOpacity))
        _opacityStatus = State(initialValue: hostActions.videoBackgroundGhosttyOpacityStatus())
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.videoBackground.enabled"),
                String(localized: "settings.terminal.videoBackground", defaultValue: "Video Background"),
                subtitle: enabled.current
                    ? String(localized: "settings.terminal.videoBackground.subtitleOn", defaultValue: "A shared video queue plays behind every terminal window. New windows join the same video and playhead.")
                    : String(localized: "settings.terminal.videoBackground.subtitleOff", defaultValue: "Terminal windows use the regular static background.")
            ) {
                Toggle("", isOn: Binding(get: { enabled.current }, set: { requestEnabled($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalVideoBackgroundToggle")
            }
            SettingsCardDivider()
            ghosttyOpacityRow
            SettingsCardDivider()
            sourceRow
            SettingsCardDivider()
            queueRow
            SettingsCardDivider()
            qualityRow
            SettingsCardDivider()
            audioRow
            SettingsCardDivider()
            volumeRow
            SettingsCardDivider()
            dimOpacityRow
        }
        .task {
            startObservingSettings()
            refreshOpacityStatus()
            if !sourceDraftLoaded {
                sourceDraft = queue.current.first ?? source.current
                sourceDraftLoaded = true
            }
        }
        .onChange(of: source.current) { oldValue, newValue in
            if queue.current.isEmpty, sourceDraft == oldValue { sourceDraft = newValue }
        }
        .onChange(of: queue.current) { oldValue, newValue in
            let oldFirst = oldValue.first ?? source.current
            let first = newValue.first ?? source.current
            if sourceDraft == oldFirst { sourceDraft = first }
        }
        .alert(
            String(localized: "settings.terminal.videoBackground.ghostty.confirm.title", defaultValue: "Allow terminal transparency?"),
            isPresented: $showGhosttySetupConfirmation
        ) {
            Button(String(localized: "settings.terminal.videoBackground.ghostty.confirm.setup", defaultValue: "Set opacity to 80%")) {
                setupGhosttyOpacity()
            }
            Button(String(localized: "settings.terminal.videoBackground.ghostty.confirm.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingEnableAfterSetup = false
            }
        } message: {
            Text(ghosttyConfirmationMessage)
        }
        .alert(
            String(localized: "settings.terminal.videoBackground.ghostty.failure.title", defaultValue: "Couldn’t update Ghostty config"),
            isPresented: $showGhosttySetupFailure
        ) {
            Button(String(localized: "settings.terminal.videoBackground.ghostty.failure.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.terminal.videoBackground.ghostty.failure.message", defaultValue: "cmux could not write background-opacity = 0.8. Check the file permissions and try again."))
        }
    }

    private var ghosttyOpacityRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.terminal.videoBackground.ghostty", defaultValue: "Ghostty transparency"),
            subtitle: String(localized: "settings.terminal.videoBackground.ghostty.subtitle", defaultValue: "Video backgrounds need background-opacity below 100%. The setup button edits cmux’s Ghostty config, not your standalone Ghostty config."),
            controlWidth: 250
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(ghosttyStatusLabel)
                    .cmuxFont(size: 11, weight: .medium, design: .rounded)
                    .foregroundColor(opacityStatus.isUsable ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.trailing)
                if !opacityStatus.configPath.isEmpty {
                    Text(opacityStatus.configPath)
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if opacityStatus.isAvailable {
                    Button(String(localized: "settings.terminal.videoBackground.ghostty.setup", defaultValue: "Set to 80%")) {
                        pendingEnableAfterSetup = false
                        showGhosttySetupConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(isSettingUpGhostty)
                }
            }
        }
    }

    private var sourceRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.videoBackground.source"),
            String(localized: "settings.terminal.videoBackground.source", defaultValue: "Video Source"),
            subtitle: String(localized: "settings.terminal.videoBackground.source.subtitle", defaultValue: "A YouTube video/playlist URL or ID, or a local .mp4/.m4v/.mov path. Press Return to set the first queue entry."),
            controlWidth: 250
        ) {
            TextField(String(localized: "settings.terminal.videoBackground.source.placeholder", defaultValue: "https://www.youtube.com/watch?v=…"), text: $sourceDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commitSourceDraft() }
                .accessibilityIdentifier("SettingsTerminalVideoBackgroundSourceField")
        }
    }

    private var queueRow: some View {
        let items = VideoBackgroundSettings().normalizedQueue(queue.current)
        return SettingsCardRow(
            configurationReview: .json("terminal.videoBackground.queue"),
            String(localized: "settings.terminal.videoBackground.queue", defaultValue: "Video Queue"),
            subtitle: String(localized: "settings.terminal.videoBackground.queue.subtitle", defaultValue: "Entries play in order and repeat. Every terminal window shares this queue and its current playhead."),
            controlWidth: 290
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                if items.isEmpty {
                    Text(String(localized: "settings.terminal.videoBackground.queue.empty", defaultValue: "No queued entries (the source above is used)."))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        queueItemRow(index: index, item: item, count: items.count)
                    }
                }
                HStack(spacing: 5) {
                    TextField(String(localized: "settings.terminal.videoBackground.queue.placeholder", defaultValue: "Add URL or file path"), text: $queueDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "settings.terminal.videoBackground.queue.add", defaultValue: "Add")) { addQueueDraft() }
                        .controlSize(.small)
                        .disabled(queueDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(String(localized: "settings.terminal.videoBackground.queue.clear", defaultValue: "Clear")) {
                        queue.set([])
                        source.set("")
                    }
                    .controlSize(.small)
                    .disabled(items.isEmpty && source.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func queueItemRow(index: Int, item: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(String.localizedStringWithFormat(String(localized: "settings.terminal.videoBackground.queue.item", defaultValue: "%lld. %@"), Int64(index + 1), item))
                .cmuxFont(size: 11)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: { moveQueueItem(index: index, offset: -1) }) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .accessibilityLabel(String(localized: "settings.terminal.videoBackground.queue.moveUp", defaultValue: "Move up"))
            Button(action: { moveQueueItem(index: index, offset: 1) }) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index >= count - 1)
                .accessibilityLabel(String(localized: "settings.terminal.videoBackground.queue.moveDown", defaultValue: "Move down"))
            Button(action: { removeQueueItem(at: index) }) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "settings.terminal.videoBackground.queue.remove", defaultValue: "Remove"))
        }
    }

    private var qualityRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.videoBackground.quality"),
            String(localized: "settings.terminal.videoBackground.quality", defaultValue: "YouTube Quality"),
            subtitle: String(localized: "settings.terminal.videoBackground.quality.subtitle", defaultValue: "Caps the decoded stream before it is scaled to fill the window. Local files use their native resolution."),
            controlWidth: 150
        ) {
            Picker("", selection: Binding(get: { VideoBackgroundSettings().normalizedQuality(quality.current) }, set: { quality.set($0) })) {
                ForEach(VideoBackgroundSettings.qualityOptions, id: \.self) { value in Text(qualityLabel(value)).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var audioRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.videoBackground.muted"),
            String(localized: "settings.terminal.videoBackground.audio", defaultValue: "Play Audio"),
            subtitle: String(localized: "settings.terminal.videoBackground.audio.subtitle", defaultValue: "Only the most recently active cmux window plays sound. Audio stops whenever playback pauses.")
        ) {
            Toggle("", isOn: Binding(get: { !muted.current }, set: { muted.set(!$0) }))
                .labelsHidden()
                .controlSize(.small)
                .disabled(!enabled.current)
                .accessibilityIdentifier("SettingsTerminalVideoBackgroundAudioToggle")
        }
    }

    private var volumeRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.videoBackground.volume"),
            String(localized: "settings.terminal.videoBackground.volume", defaultValue: "Volume"),
            subtitle: String(localized: "settings.terminal.videoBackground.volume.subtitle", defaultValue: "Volume used when Play Audio is enabled. 0% is silent and 100% is full volume."),
            controlWidth: 250
        ) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { displayedVolume }, set: { activeVolumeDragValue = $0 }), in: 0...1, step: VideoBackgroundSettings.volumeStep) { editing in
                    if !editing { commitVolumeDrag() }
                }
                .frame(width: 130)
                .disabled(!enabled.current)
                .accessibilityIdentifier("SettingsTerminalVideoBackgroundVolumeSlider")
                Text(formattedPercent(displayedVolume))
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var dimOpacityRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.videoBackground.dimOpacity"),
            String(localized: "settings.terminal.videoBackground.dimOpacity", defaultValue: "Video Dimming"),
            subtitle: String(localized: "settings.terminal.videoBackground.dimOpacity.subtitle", defaultValue: "Opacity of the terminal background over the video. The default is 80% for readable text."),
            controlWidth: 250
        ) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { displayedDimOpacity }, set: { activeDimDragValue = $0 }), in: 0...1, step: VideoBackgroundSettings.dimOpacityStep) { editing in
                    if !editing { commitDimDrag() }
                }
                .frame(width: 130)
                .disabled(!enabled.current)
                .accessibilityIdentifier("SettingsTerminalVideoBackgroundDimSlider")
                Text(formattedPercent(displayedDimOpacity))
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [enabled, source, queue, quality, muted, volume, dimOpacity]
        models.forEach { $0.startObserving() }
    }

    private func requestEnabled(_ requested: Bool) {
        guard requested else { enabled.set(false); return }
        let status = hostActions.videoBackgroundGhosttyOpacityStatus()
        opacityStatus = status
        guard status.isAvailable, !status.isUsable else { enabled.set(true); return }
        pendingEnableAfterSetup = true
        showGhosttySetupConfirmation = true
    }

    private func setupGhosttyOpacity() {
        isSettingUpGhostty = true
        Task { @MainActor in
            let succeeded = await hostActions.setVideoBackgroundGhosttyOpacity()
            isSettingUpGhostty = false
            opacityStatus = hostActions.videoBackgroundGhosttyOpacityStatus()
            if succeeded {
                if pendingEnableAfterSetup { enabled.set(true) }
                pendingEnableAfterSetup = false
            } else {
                showGhosttySetupFailure = true
            }
        }
    }

    private func refreshOpacityStatus() { opacityStatus = hostActions.videoBackgroundGhosttyOpacityStatus() }

    private var ghosttyStatusLabel: String {
        guard opacityStatus.isAvailable else { return String(localized: "settings.terminal.videoBackground.ghostty.unavailable", defaultValue: "Ghostty status unavailable") }
        let percent = Int64(((opacityStatus.opacity ?? 1) * 100).rounded())
        let format: String
        if opacityStatus.isUsable {
            format = String(localized: "settings.terminal.videoBackground.ghostty.status", defaultValue: "Current opacity: %lld%%")
        } else {
            format = String(localized: "settings.terminal.videoBackground.ghostty.statusNeedsSetup", defaultValue: "Current opacity: %lld%% — setup required")
        }
        return String.localizedStringWithFormat(format, percent)
    }

    private var ghosttyConfirmationMessage: String {
        let path = opacityStatus.configPath.isEmpty ? String(localized: "settings.terminal.videoBackground.ghostty.pathUnknown", defaultValue: "cmux’s Ghostty config") : opacityStatus.configPath
        return String.localizedStringWithFormat(String(localized: "settings.terminal.videoBackground.ghostty.confirm.message", defaultValue: "Video backgrounds are hidden by an opaque terminal. cmux will edit %@ and set background-opacity = 0.8, then reload open terminals."), path)
    }

    private func commitSourceDraft() {
        let trimmed = sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceDraft = trimmed
        var items = VideoBackgroundSettings().normalizedQueue(queue.current)
        if items.isEmpty { source.set(trimmed) }
        else if !trimmed.isEmpty { items[0] = trimmed; queue.set(items); source.set(trimmed) }
    }

    private func addQueueDraft() {
        let trimmed = queueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = VideoBackgroundSettings().normalizedQueue(queue.current)
        if items.isEmpty, !source.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(source.current) }
        items.append(trimmed)
        let normalized = VideoBackgroundSettings().normalizedQueue(items)
        queue.set(normalized)
        if source.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = normalized.first { source.set(first); sourceDraft = first }
        queueDraft = ""
    }

    private func removeQueueItem(at index: Int) {
        var items = VideoBackgroundSettings().normalizedQueue(queue.current)
        guard items.indices.contains(index) else { return }
        items.remove(at: index); queue.set(items); source.set(items.first ?? "")
    }

    private func moveQueueItem(index: Int, offset: Int) {
        var items = VideoBackgroundSettings().normalizedQueue(queue.current)
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target); queue.set(items); source.set(items.first ?? "")
    }

    private var displayedDimOpacity: Double { activeDimDragValue ?? VideoBackgroundSettings().normalizedDimOpacity(dimOpacity.current) }
    private var displayedVolume: Double { activeVolumeDragValue ?? VideoBackgroundSettings().normalizedVolume(volume.current) }
    private func commitDimDrag() { dimOpacity.set(displayedDimOpacity); activeDimDragValue = nil }
    private func commitVolumeDrag() { volume.set(displayedVolume); activeVolumeDragValue = nil }

    private func formattedPercent(_ value: Double) -> String {
        let format = String(localized: "settings.terminal.videoBackground.dimOpacity.percent", defaultValue: "%lld%%")
        return String.localizedStringWithFormat(format, Int64((value * 100).rounded()))
    }

    private func qualityLabel(_ value: String) -> String {
        switch value {
        case "720p": return String(localized: "settings.terminal.videoBackground.quality.720p", defaultValue: "720p")
        case "1440p": return String(localized: "settings.terminal.videoBackground.quality.1440p", defaultValue: "1440p")
        case "2160p": return String(localized: "settings.terminal.videoBackground.quality.2160p", defaultValue: "2160p (4K)")
        default: return String(localized: "settings.terminal.videoBackground.quality.1080p", defaultValue: "1080p (recommended)")
        }
    }
}
