public import Foundation
public import Observation

/// Persists the user's voice-engine preferences for dictation and Voice Mode.
@MainActor
@Observable
public final class VoiceSettingsStore {
    // UserDefaults is Apple-documented thread-safe; reads happen during init and writes happen on mutation.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let selectedEngineKey = "cmux.mobile.voice.selectedEngine"
    private static let voiceModeAutoSubmitKey = "cmux.mobile.voice.mode.autoSubmit"

    /// The engine the user selected in Settings. It may not be usable if its model was deleted.
    public var selectedEngine: VoiceEngineID {
        didSet { defaults.set(selectedEngine.rawValue, forKey: Self.selectedEngineKey) }
    }

    /// Whether Voice Mode appends Return after each finalized utterance.
    public var voiceModeAutoSubmit: Bool {
        didSet { defaults.set(voiceModeAutoSubmit, forKey: Self.voiceModeAutoSubmitKey) }
    }

    /// Creates a voice settings store backed by injected defaults.
    /// - Parameter defaults: The store used for persistence. Tests pass a scoped suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawEngine = defaults.string(forKey: Self.selectedEngineKey)
        self.selectedEngine = rawEngine.flatMap(VoiceEngineID.init(rawValue:)) ?? .apple
        self.voiceModeAutoSubmit = defaults.bool(forKey: Self.voiceModeAutoSubmitKey)
    }

    /// Returns the engine that should actually run for the current install state.
    /// - Parameter modelInstalled: Whether the Parakeet model exists on disk.
    /// - Returns: ``VoiceEngineID/apple`` when the selected Parakeet model is missing.
    public func effectiveEngine(modelInstalled: Bool) -> VoiceEngineID {
        if selectedEngine == .parakeetV3, !modelInstalled {
            return .apple
        }
        return selectedEngine
    }
}
