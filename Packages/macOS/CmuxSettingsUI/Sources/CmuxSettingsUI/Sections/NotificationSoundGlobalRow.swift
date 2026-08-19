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

    @State private var isValidatingCustomFile = false
    @State private var validationMessage: String?
    @State private var tasks = MainActorTaskStore<String>()
    @State private var validationRequestID: UUID?

    private static let validationTaskKey = "customSoundValidation"

    private let soundCatalog = NotificationSoundOptionCatalog()
    private let allowedContentTypes = NotificationSoundAllowedContentTypes()

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
                    .disabled(isValidatingCustomFile)

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
                        isValidatingCustomFile
                            || !canPreviewSound
                    )
                }

                if soundModel.current == NotificationSoundOverride.customFileValue {
                    customFileControls
                }

                if isValidatingCustomFile {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(String(
                            localized: "settings.notifications.sound.custom.validating",
                            defaultValue: "Validating notification sound"
                        ))
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onDisappear {
            tasks.cancel(Self.validationTaskKey)
            validationRequestID = nil
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
            .disabled(isValidatingCustomFile)
            Button(String(
                localized: "settings.notifications.sound.custom.clear.button",
                defaultValue: "Clear"
            )) {
                tasks.cancel(Self.validationTaskKey)
                validationRequestID = nil
                customFileModel.reset()
                validationMessage = nil
            }
            .controlSize(.small)
            .disabled(isValidatingCustomFile || customFileModel.current.isEmpty)
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes.all
        panel.title = String(
            localized: "settings.notifications.sound.custom.panelTitle",
            defaultValue: "Choose Notification Sound"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        tasks.cancel(Self.validationTaskKey)
        let requestID = UUID()
        validationRequestID = requestID
        isValidatingCustomFile = true
        validationMessage = nil
        tasks.replaceOnMainActor(Self.validationTaskKey) { @MainActor in
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let isValid = await hostActions.validateNotificationSoundFile(
                path: url.path
            )
            guard !Task.isCancelled, validationRequestID == requestID else { return }
            isValidatingCustomFile = false
            guard isValid else {
                validationMessage = String(
                    localized: "settings.notifications.sound.custom.invalid.message",
                    defaultValue: "The file is missing or cannot be decoded as audio."
                )
                return
            }
            customFileModel.set(url.path)
        }
    }
}
