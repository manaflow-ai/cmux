import Foundation
import os

/// Which engine ``OnDeviceDictationTranscriber`` dictates with.
///
/// Every surface (agent composer, Home, terminal, voice room) builds its
/// session with ``OnDeviceDictationTranscriber``, so the choice lives here
/// once instead of at five call sites. The app sets ``engine`` from Labs
/// (`labs.parakeetDictation`, docs/design/voice-byo-providers.md slice 3);
/// `nil`, the default, keeps the On This Mac engines.
public enum DictationEngineChoice {
    /// Makes one session's engine.
    public typealias Factory = @Sendable (DictationAudioLevelMeter?) -> any SpeechTranscribing

    // Lock carve-out: read once per dictation start from any actor, written
    // by the app when the setting changes. One reference, constant-time sections.
    private static let current = OSAllocatedUnfairLock<Factory?>(initialState: nil)

    /// The engine that replaces On This Mac, or `nil` for On This Mac.
    public static var engine: Factory? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}
