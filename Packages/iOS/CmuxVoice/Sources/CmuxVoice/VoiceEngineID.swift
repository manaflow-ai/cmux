import CmuxMobileSupport
import Foundation

/// Identifies the speech-recognition engine cmux can use on iPhone.
public enum VoiceEngineID: String, CaseIterable, Codable, Sendable {
    /// Apple's built-in Speech framework recognizer.
    case apple
    /// NVIDIA Parakeet TDT 0.6B v3 through FluidAudio/CoreML.
    case parakeetV3 = "parakeet-v3"

    /// Localized display name for settings UI.
    public var displayName: String {
        switch self {
        case .apple:
            return L10n.string("mobile.voice.engine.apple", defaultValue: "Apple Built-in")
        case .parakeetV3:
            return L10n.string("mobile.voice.engine.parakeetV3", defaultValue: "NVIDIA Parakeet v3")
        }
    }

    /// User-facing download-size label, when the engine requires a model.
    public var downloadSizeDescription: String? {
        switch self {
        case .apple:
            return nil
        case .parakeetV3:
            return L10n.string("mobile.voice.engine.parakeetV3.downloadSize", defaultValue: "483 MB")
        }
    }

    /// Whether this engine needs a downloaded CoreML model before use.
    public var requiresDownload: Bool {
        switch self {
        case .apple:
            return false
        case .parakeetV3:
            return true
        }
    }
}
