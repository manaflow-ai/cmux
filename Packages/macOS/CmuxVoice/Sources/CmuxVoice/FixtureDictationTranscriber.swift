public import Foundation

/// A microphone-free engine that "speaks" a fixed script.
///
/// UI tests and CI dogfood tours use it to drive the full dictation path
/// (HUD, level meter, partials, insertion) on runners with no microphone or
/// speech model. Each sentence of the script streams word by word as
/// partials, then lands as one final segment, like a live recognizer.
public actor FixtureDictationTranscriber: SpeechTranscribing {
    private let sentences: [String]
    private let levelMeter: DictationAudioLevelMeter?
    private let wordDelay: Duration
    private let clock: any Clock<Duration>
    private var playback: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private var pendingPartial = ""

    /// Creates a fixture engine.
    ///
    /// - Parameters:
    ///   - script: Text to dictate. Sentences split on `.`, `?`, `!` and
    ///     newlines; each becomes one final segment.
    ///   - levelMeter: Meter animated while the fixture "speaks".
    ///   - wordDelay: Pause between words.
    ///   - clock: Clock for the pauses; tests can inject a virtual clock.
    public init(
        script: String,
        levelMeter: DictationAudioLevelMeter? = nil,
        wordDelay: Duration = .milliseconds(180),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sentences = Self.sentences(in: script)
        self.levelMeter = levelMeter
        self.wordDelay = wordDelay
        self.clock = clock
    }

    public func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream()
        self.continuation = continuation
        playback = Task { [weak self] in
            await self?.play()
        }
        return stream
    }

    public func finishTranscribing() async {
        playback?.cancel()
        playback = nil
        // Like a live engine, stopping finalizes whatever was mid-utterance.
        if !pendingPartial.isEmpty {
            continuation?.yield(.final(pendingPartial))
            pendingPartial = ""
        }
        levelMeter?.reset()
        continuation?.finish()
        continuation = nil
    }

    private func play() async {
        for sentence in sentences {
            var spoken: [Substring] = []
            for word in sentence.split(separator: " ") {
                do {
                    try await clock.sleep(for: wordDelay)
                } catch {
                    return
                }
                spoken.append(word)
                pendingPartial = spoken.joined(separator: " ")
                // A rough speech envelope so the meter moves like a voice.
                levelMeter?.update(rms: 0.02 + 0.03 * Float(word.count % 4))
                continuation?.yield(.partial(pendingPartial))
            }
            levelMeter?.update(rms: 0)
            pendingPartial = ""
            continuation?.yield(.final(sentence))
        }
    }

    static func sentences(in script: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in script {
            if character.isNewline {
                appendTrimmed(&current, to: &result)
                continue
            }
            current.append(character)
            if ".?!".contains(character) {
                appendTrimmed(&current, to: &result)
            }
        }
        appendTrimmed(&current, to: &result)
        return result
    }

    private static func appendTrimmed(_ text: inout String, to result: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }
        text = ""
    }
}
