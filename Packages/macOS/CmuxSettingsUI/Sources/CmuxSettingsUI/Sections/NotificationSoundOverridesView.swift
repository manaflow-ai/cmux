import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Sparse agent × alert sound editor. It owns only the serialized matrix;
/// discovery, file validation, and persistence remain host/catalog concerns.
@MainActor
struct NotificationSoundOverridesView: View {
    /// Bounded matrix parsed by the parent-owned cache.
    let parsedOverrides: NotificationSoundOverrides
    /// Applies one cell mutation against the parent's live settings snapshot.
    /// Keeping this closure at the parent boundary prevents an async file
    /// validation result from overwriting a newer edit in another cell.
    let onChange: @MainActor (
        NotificationSoundOverride?,
        String,
        NotificationSoundAlertType
    ) -> Void
    let hostActions: SettingsHostActions
    let agents: [NotificationSoundAgentOption]
    /// True when the persisted JSON could not be decoded. Editing is disabled
    /// so a recovery attempt cannot silently replace unrelated valid cells.
    var isPersistedValueMalformed: Bool = false

    @State private var filePicker: NotificationSoundFilePickerModel

    private let alertTypes = NotificationSoundAlertType.allCases
    private let soundCatalog = NotificationSoundOptionCatalog()
    init(
        parsedOverrides: NotificationSoundOverrides,
        isPersistedValueMalformed: Bool = false,
        onChange: @escaping @MainActor (
            NotificationSoundOverride?,
            String,
            NotificationSoundAlertType
        ) -> Void,
        hostActions: SettingsHostActions,
        agents: [NotificationSoundAgentOption]
    ) {
        self.parsedOverrides = parsedOverrides
        self.isPersistedValueMalformed = isPersistedValueMalformed
        self.onChange = onChange
        self.hostActions = hostActions
        self.agents = agents
        _filePicker = State(
            initialValue: NotificationSoundFilePickerModel(hostActions: hostActions)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPersistedValueMalformed {
                Text(String(
                    localized: "settings.notifications.soundOverrides.invalidConfiguration",
                    defaultValue: "The saved per-agent sound settings are invalid. Fix notifications.soundOverrides in cmux.json before editing."
                ))
                .font(.caption)
                .foregroundStyle(.red)
            }

            Text(String(
                localized: "settings.notifications.soundOverrides.help",
                defaultValue: "Choose a sound for each agent and alert type. Empty cells use the global notification sound."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if agents.isEmpty {
                Text(String(
                    localized: "settings.notifications.soundOverrides.noAgents",
                    defaultValue: "No registered agents found."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text(String(localized: "settings.notifications.soundOverrides.agent", defaultValue: "Agent"))
                            .font(.caption.weight(.semibold))
                        ForEach(alertTypes, id: \.self) { alertType in
                            Text(label(for: alertType))
                                .font(.caption.weight(.semibold))
                        }
                    }
                    ForEach(agents) { agent in
                        GridRow {
                            Text(agent.displayName)
                                .lineLimit(1)
                                .frame(minWidth: 120, alignment: .leading)
                            ForEach(alertTypes, id: \.self) { alertType in
                                cell(
                                    for: agent,
                                    alertType: alertType,
                                    overrides: parsedOverrides
                                )
                            }
                        }
                    }
                }
                .disabled(isPersistedValueMalformed)
            }

            if let validationMessage = filePicker.validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if filePicker.isValidating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(
                        localized: "settings.notifications.sound.custom.validating",
                        defaultValue: "Validating notification sound"
                    ))
            }
        }
        .accessibilityIdentifier("NotificationSoundOverridesMatrix")
        .onDisappear {
            filePicker.cancel()
        }
    }

    @ViewBuilder
    private func cell(
        for agent: NotificationSoundAgentOption,
        alertType: NotificationSoundAlertType,
        overrides: NotificationSoundOverrides
    ) -> some View {
        let current = overrides.override(forAgentID: agent.id, alertType: alertType)
        Menu {
            Button(String(localized: "settings.notifications.soundOverrides.useGlobal", defaultValue: "Use Global Sound")) {
                update(nil, agentID: agent.id, alertType: alertType)
            }
            Divider()
            ForEach(soundCatalog.options, id: \.value) { option in
                if option.value != NotificationSoundOverride.customFileValue {
                    Button(soundLabel(for: option.value)) {
                        guard let override = NotificationSoundOverride(sound: option.value) else { return }
                        update(override, agentID: agent.id, alertType: alertType)
                    }
                }
            }
            Divider()
            Button(String(localized: "settings.notifications.soundOverrides.chooseCustom", defaultValue: "Choose Custom File…")) {
                chooseCustomFile(agentID: agent.id, alertType: alertType)
            }
        } label: {
            Text(currentLabel(current))
                .frame(width: 132, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(filePicker.isValidating)
    }

    private func update(
        _ value: NotificationSoundOverride?,
        agentID: String,
        alertType: NotificationSoundAlertType
    ) {
        onChange(value, agentID, alertType)
        filePicker.clearMessage()
    }

    private func chooseCustomFile(agentID: String, alertType: NotificationSoundAlertType) {
        let onChange = self.onChange
        filePicker.choose(
            title: String(
                localized: "settings.notifications.soundOverrides.chooseCustom.title",
                defaultValue: "Choose Notification Sound"
            ),
            invalidMessage: String(
                localized: "settings.notifications.soundOverrides.invalidFile",
                defaultValue: "That file is missing or cannot be decoded as audio."
            ),
            onValid: { path in
                guard let value = NotificationSoundOverride(
                    sound: NotificationSoundOverride.customFileValue,
                    customSoundFilePath: path
                ) else { return }
                onChange(value, agentID, alertType)
            }
        )
    }

    private func label(for alertType: NotificationSoundAlertType) -> String {
        switch alertType {
        case .turnDone:
            return String(localized: "settings.notifications.soundOverrides.turnDone", defaultValue: "Turn Done")
        case .needsInput:
            return String(localized: "settings.notifications.soundOverrides.needsInput", defaultValue: "Needs Input")
        case .errorStalled:
            return String(localized: "settings.notifications.soundOverrides.errorStalled", defaultValue: "Error / Stalled")
        }
    }

    private func soundLabel(for value: String) -> String {
        guard let option = soundCatalog.descriptor(for: value) else {
            return value
        }
        return soundCatalog.localizedLabel(for: option)
    }

    private func currentLabel(_ value: NotificationSoundOverride?) -> String {
        guard let value else {
            return String(localized: "settings.notifications.soundOverrides.global", defaultValue: "Global")
        }
        if value.sound == NotificationSoundOverride.customFileValue {
            return String(localized: "settings.notifications.soundOverrides.custom", defaultValue: "Custom")
        }
        return soundLabel(for: value.sound)
    }
}
