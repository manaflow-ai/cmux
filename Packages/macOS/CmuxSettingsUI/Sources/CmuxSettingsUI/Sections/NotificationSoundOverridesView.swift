import AppKit
import CmuxSettings
import CmuxFoundation
import SwiftUI

/// Focused agent × alert sound editor.
///
/// The editor keeps the agent registry behind one picker and shows only the
/// three categories for the selected agent. This avoids rendering a large
/// matrix of mostly-global values while keeping every override editable.
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
    let agents: [NotificationSoundAgentOption]
    /// True when the persisted JSON could not be decoded. Editing is disabled
    /// so a recovery attempt cannot silently replace unrelated valid cells.
    var isPersistedValueMalformed: Bool = false

    @State private var filePicker: NotificationSoundFilePickerModel
    @State private var selectedAgentID: String?

    private let alertTypes = NotificationSoundAlertType.allCases

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
        self.agents = agents
        _filePicker = State(
            initialValue: NotificationSoundFilePickerModel(hostActions: hostActions)
        )
        let configuredAgentIDs = Set(parsedOverrides.agentIDs)
        _selectedAgentID = State(
            initialValue: agents.first(where: { configuredAgentIDs.contains($0.id) })?.id
                ?? agents.first?.id
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isPersistedValueMalformed {
                Text(String(
                    localized: "settings.notifications.soundOverrides.invalidConfiguration",
                    defaultValue: "The saved per-agent sound settings are invalid. Fix notifications.soundOverrides in cmux.json before editing."
                ))
                .font(.caption)
                .foregroundStyle(.red)
            }

            if agents.isEmpty {
                Text(String(
                    localized: "settings.notifications.soundOverrides.noAgents",
                    defaultValue: "No registered agents found."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                if let selectedAgent {
                    editor(for: selectedAgent)
                }
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
        .onAppear {
            ensureSelection()
        }
        .onChange(of: agents) { _, _ in
            ensureSelection()
        }
        .onDisappear {
            filePicker.cancel()
        }
    }

    private var selectedAgent: NotificationSoundAgentOption? {
        guard !agents.isEmpty else { return nil }
        if let selectedAgentID,
           let matchingAgent = agents.first(where: { $0.id == selectedAgentID }) {
            return matchingAgent
        }
        return agents[0]
    }

    private var selectedAgentBinding: Binding<String> {
        Binding(
            get: { selectedAgent?.id ?? agents.first?.id ?? "" },
            set: { selectedAgentID = $0 }
        )
    }

    private var agentPicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.13), in: Circle())

            Text(String(
                localized: "settings.notifications.soundOverrides.agent",
                defaultValue: "Agent"
            ))
            .cmuxFont(size: 13, weight: .medium)

            Spacer(minLength: 8)

            Picker(
                selectedAgent?.displayName ?? String(
                    localized: "settings.notifications.soundOverrides.agent",
                    defaultValue: "Agent"
                ),
                selection: selectedAgentBinding
            ) {
                ForEach(agents) { agent in
                    Text(agent.displayName).tag(agent.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(minWidth: 190, alignment: .trailing)
            .disabled(isPersistedValueMalformed || filePicker.isValidating)
            .accessibilityIdentifier("NotificationSoundOverridesAgentPicker")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func editor(for agent: NotificationSoundAgentOption) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            agentPicker
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 1)

            ForEach(Array(alertTypes.enumerated()), id: \.element) { index, alertType in
                if index > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.28))
                        .frame(height: 1)
                        .padding(.leading, 50)
                }
                NotificationSoundOverrideEditorRow(
                    alertType: alertType,
                    currentOverride: parsedOverrides.override(
                        forAgentID: agent.id,
                        alertType: alertType
                    ),
                    isDisabled: isPersistedValueMalformed || filePicker.isValidating,
                    onSelect: { value in
                        update(value, agentID: agent.id, alertType: alertType)
                    },
                    onChooseCustom: {
                        chooseCustomFile(agentID: agent.id, alertType: alertType)
                    }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
        .disabled(isPersistedValueMalformed)
        .accessibilityIdentifier("NotificationSoundOverridesSelectedAgent")
    }

    private func ensureSelection() {
        guard let firstAgent = agents.first else {
            selectedAgentID = nil
            return
        }
        guard let selectedAgentID,
              agents.contains(where: { $0.id == selectedAgentID }) else {
            self.selectedAgentID = firstAgent.id
            return
        }
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
}
