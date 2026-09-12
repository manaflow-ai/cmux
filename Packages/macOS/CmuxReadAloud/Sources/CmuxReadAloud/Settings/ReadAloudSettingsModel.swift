import Foundation
import Observation

/// Owns editable Read Aloud settings and reports the outcome of each persistence action.
///
/// Construct once at the app composition root and pass it to ``ReadAloudSettingsView``.
/// Speech settings remain drafts until saved; consent and credential state change only
/// after the preferences actor completes the corresponding operation.
@MainActor
@Observable
public final class ReadAloudSettingsModel {
    var selectedModel = ReadAloudConfiguration().model
    var voiceID = ReadAloudConfiguration().voiceID
    var speed = ReadAloudConfiguration().speed
    var apiKeyDraft = ""
    private(set) var consentGranted = false
    private(set) var hasSavedAPIKey: Bool?
    private(set) var isBusy = false
    private(set) var isLoaded = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private var savedConfiguration = ReadAloudConfiguration()
    private let preferences: ReadAloudPreferences

    /// Creates settings state without reading the Keychain or automatically granting consent.
    /// - Parameter preferences: The same preferences actor used by the Read Aloud coordinator.
    public init(preferences: ReadAloudPreferences) {
        self.preferences = preferences
    }

    var hasUnsavedConfiguration: Bool {
        selectedModel != savedConfiguration.model
            || voiceID.trimmingCharacters(in: .whitespacesAndNewlines) != savedConfiguration.voiceID
            || speed != savedConfiguration.speed
    }

    var canSaveAPIKey: Bool {
        !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum Action {
        case load
        case saveConfiguration
        case saveAPIKey
        case removeAPIKey
        case setConsent(Bool)
    }

    /// Serializes every settings persistence action and exposes only confirmed results.
    func perform(_ action: Action) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }

        do {
            switch action {
            case .load:
                savedConfiguration = await preferences.configuration()
                selectedModel = savedConfiguration.model
                voiceID = savedConfiguration.voiceID
                speed = savedConfiguration.speed
                consentGranted = await preferences.consentGranted()
                isLoaded = true
                hasSavedAPIKey = nil
                hasSavedAPIKey = try await preferences.hasAPIKey()
            case .saveConfiguration:
                let requested = try ReadAloudConfiguration(model: selectedModel, voiceID: voiceID, speed: speed)
                try await preferences.save(configuration: requested)
                savedConfiguration = requested
                statusMessage = String(localized: "status.settingsSaved", defaultValue: "Speech settings saved.", table: "ReadAloudSettings", bundle: .module)
            case .saveAPIKey:
                try await preferences.saveAPIKey(apiKeyDraft)
                apiKeyDraft = ""
                hasSavedAPIKey = true
                statusMessage = String(localized: "status.keySaved", defaultValue: "API key saved in Keychain.", table: "ReadAloudSettings", bundle: .module)
            case .removeAPIKey:
                try await preferences.removeAPIKey()
                apiKeyDraft = ""
                hasSavedAPIKey = false
                statusMessage = String(localized: "status.keyRemoved", defaultValue: "API key removed from Keychain.", table: "ReadAloudSettings", bundle: .module)
            case .setConsent(let granted):
                await preferences.setConsentGranted(granted)
                consentGranted = await preferences.consentGranted()
            }
        } catch let error as ReadAloudPreferencesError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = String(localized: "error.persistence", defaultValue: "Read Aloud settings could not be saved. Your change was not confirmed. Try again.", table: "ReadAloudSettings", bundle: .module)
        }
    }
}
