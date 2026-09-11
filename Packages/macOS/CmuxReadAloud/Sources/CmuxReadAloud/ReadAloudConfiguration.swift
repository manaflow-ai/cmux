import Foundation

/// An immutable, validated snapshot shared by persistence and speech synthesis.
public struct ReadAloudConfiguration: Codable, Equatable, Sendable {
    /// Models supported by both the settings interface and speech transport.
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// Lower-latency speech synthesis.
        case turbo = "speech-2.8-turbo"
        /// Higher-quality speech synthesis.
        case hd = "speech-2.8-hd"
    }

    /// Supported MiniMax speech model.
    public let model: Model
    /// Nonempty voice identifier containing no control characters.
    public let voiceID: String
    /// Finite synthesis speed from 0.5 through 2.0.
    public let speed: Double

    /// Creates the supported default configuration without reading stored preferences.
    public init() {
        model = .turbo
        voiceID = "English_expressive_narrator"
        speed = 1.0
    }

    /// Validates editable settings before they become runtime preferences.
    /// - Parameters:
    ///   - model: The supported provider model; defaults to Turbo.
    ///   - voiceID: A nonempty voice identifier without control characters.
    ///   - speed: A finite synthesis speed from 0.5 through 2.0; defaults to 1.
    /// - Throws: A localized settings error if the voice or speed is invalid.
    public init(model: Model = .turbo, voiceID: String, speed: Double = 1.0) throws {
        guard !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !voiceID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReadAloudPreferencesError.emptyVoice
        }
        guard speed.isFinite, (0.5...2.0).contains(speed) else {
            throw ReadAloudPreferencesError.invalidSpeed
        }
        self.model = model
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speed = speed
    }

    /// Decodes existing string-based preferences through the same validation as settings.
    /// - Parameter decoder: The persisted configuration decoder.
    /// - Throws: A decoding or validation error for unsupported stored values.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            model: values.decode(Model.self, forKey: .model),
            voiceID: values.decode(String.self, forKey: .voiceID),
            speed: values.decode(Double.self, forKey: .speed)
        )
    }
}
