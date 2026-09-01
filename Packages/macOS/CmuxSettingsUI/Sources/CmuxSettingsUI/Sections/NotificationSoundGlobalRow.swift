import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The existing global notification-sound picker and asynchronous custom-file validator.
@MainActor
struct NotificationSoundGlobalRow: View {
    let soundModel: DefaultsValueModel<String>
    let customFileModel: DefaultsValueModel<String>
    let hostActions: SettingsHostActions

    @State private var filePicker: NotificationSoundFilePickerModel

    private let soundCatalog = NotificationSoundOptionCatalog()

    init(
        soundModel: DefaultsValueModel<String>,
        customFileModel: DefaultsValueModel<String>,
        hostActions: SettingsHostActions
    ) {
        self.soundModel = soundModel
        self.customFileModel = customFileModel
        self.hostActions = hostActions
        _filePicker = State(
            initialValue: NotificationSoundFilePickerModel(hostActions: hostActions)
        )
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json(
                "notifications.sound",
                "notifications.customSoundFilePath"
            ),
            String(
                localized: "settings.notifications.sound.title",
                defaultValue: "Notification Sound"
            ),
            subtitle: String(
                localized: "settings.notifications.sound.subtitle",
                defaultValue: "Sound played when a notification arrives."
            ),
            controlWidth: 280
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { soundModel.current },
                            set: { soundModel.set($0) }
                        )
                    ) {
                        ForEach(soundCatalog.options, id: \.value) { option in
                            Text(soundCatalog.localizedLabel(for: option))
                                .tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .disabled(filePicker.isValidating)

                    Button {
                        hostActions.previewNotificationSound(
                            value: soundModel.current,
                            customFilePath: customFileModel.current
                        )
                    } label: {
                        Image(systemName: "play.fill")
                            .cmuxFont(size: 9)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        filePicker.isValidating
                            || !canPreviewSound
                    )
                }

                if soundModel.current == NotificationSoundOverride.customFileValue {
                    customFileControls
                }

                if filePicker.isValidating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(String(
                            localized: "settings.notifications.sound.custom.validating",
                            defaultValue: "Validating notification sound"
                        ))
                }

                if let validationMessage = filePicker.validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onDisappear {
            filePicker.cancel()
        }
    }

    private var customFileControls: some View {
        HStack(spacing: 6) {
            Text(customFileDisplayName)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .trailing)
            Button(String(
                localized: "settings.notifications.sound.custom.choose.button",
                defaultValue: "Choose…"
            )) {
                chooseCustomSound()
            }
            .controlSize(.small)
            .disabled(filePicker.isValidating)
            Button(String(
                localized: "settings.notifications.sound.custom.clear.button",
                defaultValue: "Clear"
            )) {
                filePicker.cancel()
                customFileModel.reset()
                filePicker.clearMessage()
            }
            .controlSize(.small)
            .disabled(filePicker.isValidating || customFileModel.current.isEmpty)
        }
    }

    private var customFileDisplayName: String {
        let path = customFileModel.current.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !path.isEmpty else {
            return String(
                localized: "settings.notifications.sound.custom.file.none",
                defaultValue: "No file selected"
            )
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var canPreviewSound: Bool {
        switch soundModel.current {
        case NotificationSoundOverride.noneValue:
            return false
        case NotificationSoundOverride.customFileValue:
            return !customFileModel.current.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        default:
            return true
        }
    }

    private func chooseCustomSound() {
        let customFileModel = self.customFileModel
        filePicker.choose(
            title: String(
                localized: "settings.notifications.sound.custom.panelTitle",
                defaultValue: "Choose Notification Sound"
            ),
            invalidMessage: String(
                localized: "settings.notifications.sound.custom.invalid.message",
                defaultValue: "The file is missing or cannot be decoded as audio."
            ),
            onValid: { path in
                customFileModel.set(path)
            }
        )
    }
}
