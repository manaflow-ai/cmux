import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Compact editor for one alert category in the selected agent's sound profile.
@MainActor
struct NotificationSoundOverrideEditorRow: View {
    let alertType: NotificationSoundAlertType
    let currentOverride: NotificationSoundOverride?
    let isDisabled: Bool
    let onSelect: @MainActor (NotificationSoundOverride?) -> Void
    let onChooseCustom: @MainActor () -> Void

    private let soundCatalog = NotificationSoundOptionCatalog()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 26)
                .background(iconColor.opacity(0.14), in: Circle())

            Text(alertLabel)
                .cmuxFont(size: 13, weight: .medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button(String(
                    localized: "settings.notifications.soundOverrides.useGlobal",
                    defaultValue: "Use Global Sound"
                )) {
                    onSelect(nil)
                }
                Divider()
                ForEach(soundCatalog.options, id: \.value) { option in
                    if option.value != NotificationSoundOverride.customFileValue {
                        Button(soundCatalog.localizedLabel(for: option)) {
                            guard let override = NotificationSoundOverride(sound: option.value) else {
                                return
                            }
                            onSelect(override)
                        }
                    }
                }
                Divider()
                Button(String(
                    localized: "settings.notifications.soundOverrides.chooseCustom",
                    defaultValue: "Choose Custom File…"
                )) {
                    onChooseCustom()
                }
            } label: {
                Text(currentLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 150, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .disabled(isDisabled)
            .accessibilityLabel(alertLabel)
            .accessibilityValue(currentLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var iconName: String {
        switch alertType {
        case .turnDone:
            return "checkmark.circle.fill"
        case .needsInput:
            return "hand.raised.fill"
        case .errorStalled:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch alertType {
        case .turnDone:
            return .green
        case .needsInput:
            return .orange
        case .errorStalled:
            return .red
        }
    }

    private var alertLabel: String {
        switch alertType {
        case .turnDone:
            return String(
                localized: "settings.notifications.soundOverrides.turnDone",
                defaultValue: "Turn Done"
            )
        case .needsInput:
            return String(
                localized: "settings.notifications.soundOverrides.needsInput",
                defaultValue: "Needs Input"
            )
        case .errorStalled:
            return String(
                localized: "settings.notifications.soundOverrides.errorStalled",
                defaultValue: "Error / Stalled"
            )
        }
    }

    private var currentLabel: String {
        guard let currentOverride else {
            return String(
                localized: "settings.notifications.soundOverrides.global",
                defaultValue: "Global"
            )
        }
        if currentOverride.sound == NotificationSoundOverride.customFileValue {
            return String(
                localized: "settings.notifications.soundOverrides.custom",
                defaultValue: "Custom"
            )
        }
        guard let descriptor = soundCatalog.descriptor(for: currentOverride.sound) else {
            return currentOverride.sound
        }
        return soundCatalog.localizedLabel(for: descriptor)
    }
}
