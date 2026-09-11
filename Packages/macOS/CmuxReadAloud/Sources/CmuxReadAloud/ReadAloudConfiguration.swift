import Foundation

/// Validated runtime preferences for reading selected text through MiniMax.
public struct ReadAloudConfiguration: Codable, Equatable, Sendable {
    public var model: String
    public var voiceID: String
    public var speed: Double

    public init(model: String = "speech-2.8-turbo", voiceID: String = "English_expressive_narrator", speed: Double = 1.0) {
        self.model = model; self.voiceID = voiceID; self.speed = speed
    }

    /// Validates the complete runtime snapshot against the supported provider contract.
    public func validate() throws {
        guard model == "speech-2.8-turbo" || model == "speech-2.8-hd" else { throw ConfigurationError.unsupportedModel }
        guard !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !voiceID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ConfigurationError.invalidVoice }
        guard speed.isFinite, (0.5...2.0).contains(speed) else { throw ConfigurationError.invalidSpeed }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(model: try c.decode(String.self, forKey: .model), voiceID: try c.decode(String.self, forKey: .voiceID), speed: try c.decode(Double.self, forKey: .speed))
        try validate()
    }

    public enum ConfigurationError: Error, Equatable { case unsupportedModel, invalidVoice, invalidSpeed }
}
