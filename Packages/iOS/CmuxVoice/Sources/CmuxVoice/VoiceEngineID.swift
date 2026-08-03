import CmuxMobileSupport
import Foundation

/// Identifies the speech-recognition engine cmux can use on iPhone.
public enum VoiceEngineID: String, CaseIterable, Codable, Sendable {
    /// Apple's built-in Speech framework recognizer.
    case apple
    /// NVIDIA Parakeet TDT 0.6B v3 through FluidAudio/CoreML.
    case parakeetV3 = "parakeet-v3"
    /// NVIDIA Parakeet TDT 0.6B v3 using the smaller int4 encoder.
    case parakeetV3Int4 = "parakeet-v3-int4"
    /// NVIDIA Parakeet TDT 0.6B v2, English-focused.
    case parakeetV2 = "parakeet-v2"

    /// Decodes unknown persisted/codable values as Apple so removed or newer engines fail closed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? ""
        self = VoiceEngineID(rawValue: rawValue) ?? .apple
    }

    /// Encodes the stable raw value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Localized display name for settings UI.
    public var displayName: String {
        switch self {
        case .apple:
            return L10n.string("mobile.voice.engine.apple", defaultValue: "Apple Built-in")
        case .parakeetV3:
            return L10n.string("mobile.voice.engine.parakeetV3", defaultValue: "NVIDIA Parakeet v3")
        case .parakeetV3Int4:
            return L10n.string("mobile.voice.engine.parakeetV3Int4", defaultValue: "NVIDIA Parakeet v3 Compact")
        case .parakeetV2:
            return L10n.string("mobile.voice.engine.parakeetV2", defaultValue: "NVIDIA Parakeet v2 (English)")
        }
    }

    /// One-line description for downloadable model rows.
    public var caption: String? {
        switch self {
        case .apple:
            return nil
        case .parakeetV3:
            return L10n.string("mobile.voice.engine.parakeetV3.caption", defaultValue: "25 languages · best accuracy")
        case .parakeetV3Int4:
            return L10n.string("mobile.voice.engine.parakeetV3Int4.caption", defaultValue: "25 languages · smaller download")
        case .parakeetV2:
            return L10n.string("mobile.voice.engine.parakeetV2.caption", defaultValue: "English only · fastest English")
        }
    }

    /// User-facing download-size label, when the engine requires a model.
    public var downloadSizeDescription: String? {
        switch self {
        case .apple:
            return nil
        case .parakeetV3:
            return L10n.string("mobile.voice.engine.parakeetV3.downloadSize", defaultValue: "483 MB")
        case .parakeetV3Int4:
            return L10n.string("mobile.voice.engine.parakeetV3Int4.downloadSize", defaultValue: "336 MB")
        case .parakeetV2:
            return L10n.string("mobile.voice.engine.parakeetV2.downloadSize", defaultValue: "464 MB")
        }
    }

    /// Whether this engine needs a downloaded CoreML model before use.
    public var requiresDownload: Bool {
        switch self {
        case .apple:
            return false
        case .parakeetV3, .parakeetV3Int4, .parakeetV2:
            return true
        }
    }

    /// Downloadable engines in settings display order.
    public static var downloadableCases: [VoiceEngineID] {
        [.parakeetV3, .parakeetV3Int4, .parakeetV2]
    }
}
