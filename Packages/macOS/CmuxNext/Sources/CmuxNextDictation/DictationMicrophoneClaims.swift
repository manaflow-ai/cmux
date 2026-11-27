import Foundation

/// The one microphone the app's dictation surfaces share: the agent panes'
/// composers and Home's message box. A surface claims it when it starts
/// listening; a claim from another surface first stops the holder's session
/// (keeping its words), so at most one listens at a time. The holder gives
/// it back when its session ends.
@MainActor
public final class DictationMicrophoneClaims {
    /// The app's claims (tests make their own).
    public static let shared = DictationMicrophoneClaims()

    private weak var holder: AnyObject?
    private var stopHolder: (@MainActor () -> Void)?

    /// The person's own dictation provider (`agentPane.dictationEngine`), asked as each session
    /// starts: nil (on-device, the default) dictates with ``OnDeviceDictationTranscriber`` as
    /// before; a transcription records the session and has the provider transcribe it on stop
    /// (``RecordedDictationTranscriber``). Set once for the surfaces that share this microphone.
    public var providerTranscription: (@MainActor () -> RecordedDictationTranscriber.Transcribe?)?

    public init() {}

    /// A session with the person's engine: their provider's when one is set, else on-device.
    public func session() -> DictationSession {
        DictationSession(makeTranscriber: { [weak self] meter in
            if let transcribe = self?.providerTranscription?() {
                return RecordedDictationTranscriber(levelMeter: meter, transcribe: transcribe)
            }
            return OnDeviceDictationTranscriber(levelMeter: meter)
        })
    }

    /// `owner` starts listening: whoever else holds the microphone stops first.
    /// - Parameters:
    ///   - owner: The surface that listens now (held weakly).
    ///   - stop: Stops `owner`'s session, keeping its words; run when another surface claims.
    public func claim(_ owner: AnyObject, stop: @escaping @MainActor () -> Void) {
        if let holder, holder !== owner {
            let previous = stopHolder
            stopHolder = nil
            self.holder = nil
            previous?()
        }
        holder = owner
        stopHolder = stop
    }

    /// `owner`'s session ended; a claim held by someone else stays.
    public func release(_ owner: AnyObject) {
        guard holder === owner else { return }
        holder = nil
        stopHolder = nil
    }

    /// Stops whoever holds the microphone, keeping their words: another app takes it now (the
    /// composer mic's hand-off to a dictation app).
    public func yield() {
        let previous = stopHolder
        (holder, stopHolder) = (nil, nil)
        previous?()
    }

    /// Whether any of cmux's surfaces holds the microphone now.
    public var isHeld: Bool { holder != nil }

    /// Whether `owner` holds the microphone now.
    public func isHeld(by owner: AnyObject) -> Bool { holder === owner }
}
