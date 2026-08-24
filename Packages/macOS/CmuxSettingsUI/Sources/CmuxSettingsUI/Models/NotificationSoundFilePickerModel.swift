import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation
import Observation

/// Shared owner for custom notification-sound selection and validation.
///
/// Both the global sound row and every matrix cell use the same cancellation,
/// security-scope, and stale-result rules. The owner is main-actor isolated
/// because it drives AppKit's modal panel and the observable Settings state;
/// validation itself is delegated to the host's asynchronous staging service.
@MainActor
@Observable
final class NotificationSoundFilePickerModel {
    private static let validationTaskKey = "customSoundValidation"

    private let hostActions: SettingsHostActions
    private let allowedContentTypes = NotificationSoundAllowedContentTypes()
    @ObservationIgnored private let tasks = MainActorTaskStore<String>()
    @ObservationIgnored private var validationRequestID: UUID?

    private(set) var isValidating = false
    private(set) var validationMessage: String?

    init(hostActions: SettingsHostActions) {
        self.hostActions = hostActions
    }

    deinit {}

    /// Presents a picker and validates the selected file before invoking
    /// `onValid`. A newer selection or disappearance cancels the prior task.
    func choose(
        title: String,
        invalidMessage: String,
        onValid: @escaping @MainActor @Sendable (String) -> Void
    ) {
        guard !isValidating else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes.all
        panel.title = title
        guard panel.runModal() == .OK, let url = panel.url else { return }

        tasks.cancel(Self.validationTaskKey)
        let requestID = UUID()
        validationRequestID = requestID
        isValidating = true
        validationMessage = nil
        let path = url.path
        tasks.replaceOnMainActor(Self.validationTaskKey) { @MainActor [weak self] in
            guard let self else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let isValid = await hostActions.validateNotificationSoundFile(path: path)
            guard !Task.isCancelled, validationRequestID == requestID else { return }
            isValidating = false
            guard isValid else {
                validationMessage = invalidMessage
                return
            }
            onValid(path)
        }
    }

    /// Cancels validation and clears the visible transient state.
    func cancel() {
        tasks.cancel(Self.validationTaskKey)
        validationRequestID = nil
        isValidating = false
    }

    /// Clears only the last validation message, preserving an in-flight task.
    func clearMessage() {
        validationMessage = nil
    }
}
