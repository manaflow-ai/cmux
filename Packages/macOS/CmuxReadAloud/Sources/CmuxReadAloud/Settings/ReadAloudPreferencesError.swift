import Foundation
import Security

/// Settings failures contain no submitted credential, voice identifier, or selected text.
enum ReadAloudPreferencesError: LocalizedError {
    case unsupportedModel
    case emptyVoice
    case invalidSpeed
    case emptyCredential
    case invalidCredential
    case invalidService
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            String(localized: "error.unsupportedModel", defaultValue: "Choose the Turbo or HD speech-2.8 model.", table: "ReadAloudSettings", bundle: .module)
        case .emptyVoice:
            String(localized: "error.emptyVoice", defaultValue: "Enter a MiniMax voice ID.", table: "ReadAloudSettings", bundle: .module)
        case .invalidSpeed:
            String(localized: "error.invalidSpeed", defaultValue: "Speech speed must be a finite number from 0.5 to 2.", table: "ReadAloudSettings", bundle: .module)
        case .emptyCredential:
            String(localized: "error.emptyCredential", defaultValue: "Enter a MiniMax API key before saving.", table: "ReadAloudSettings", bundle: .module)
        case .invalidCredential:
            String(localized: "error.invalidCredential", defaultValue: "The saved API key cannot be read. Replace or remove it in Read Aloud settings.", table: "ReadAloudSettings", bundle: .module)
        case .invalidService:
            String(localized: "error.invalidService", defaultValue: "The app has not configured a Keychain service for Read Aloud.", table: "ReadAloudSettings", bundle: .module)
        case .keychain:
            String(localized: "error.keychain", defaultValue: "Keychain could not complete the operation. Your requested change was not confirmed. Try again.", table: "ReadAloudSettings", bundle: .module)
        }
    }
}
