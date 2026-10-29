import Foundation
import Observation

/// A voice model a Chief call can use (the Realtime API's speech-to-speech models).
public struct VoiceCallModelChoice: Hashable, Sendable, Identifiable {
    /// The API model id.
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    /// gpt-realtime-2.1 (July 2026): the newest Realtime reasoning model, the default.
    public static let standard = VoiceCallModelChoice(
        id: "gpt-realtime-2.1", title: "GPT Realtime 2.1", detail: String(localized: "Best at reasoning and actions"))
    /// gpt-realtime-2.1-mini: the distilled model, faster and cheaper.
    public static let mini = VoiceCallModelChoice(
        id: "gpt-realtime-2.1-mini", title: "GPT Realtime 2.1 mini", detail: String(localized: "Faster and cheaper"))
    public static let all: [VoiceCallModelChoice] = [standard, mini]
}

/// A voice Chief can speak with. Marin and Cedar sound best (OpenAI's guidance).
public struct VoiceCallVoice: Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String { id.prefix(1).uppercased() + id.dropFirst() }

    public init(id: String) {
        self.id = id
    }

    public static let all: [VoiceCallVoice] = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
        .map(VoiceCallVoice.init(id:))
}

/// This phone's choices for Chief calls: model and voice. Not secret, so
/// they live in user defaults; the API key lives in the Keychain
/// (``OpenAIKeyStore``).
@MainActor
@Observable
public final class VoiceCallPreferences {
    public static let shared = VoiceCallPreferences()

    public var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.model) }
    }
    public var voiceID: String {
        didSet { defaults.set(voiceID, forKey: Keys.voice) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let model = defaults.string(forKey: Keys.model)
        modelID = VoiceCallModelChoice.all.contains { $0.id == model } ? model ?? VoiceCallModelChoice.standard.id
            : VoiceCallModelChoice.standard.id
        let voice = defaults.string(forKey: Keys.voice)
        voiceID = VoiceCallVoice.all.contains { $0.id == voice } ? voice ?? "marin" : "marin"
    }

    public var model: VoiceCallModelChoice {
        VoiceCallModelChoice.all.first { $0.id == modelID } ?? .standard
    }

    private struct Keys {
        static let model = "chiefCall.model"
        static let voice = "chiefCall.voice"
    }
}
