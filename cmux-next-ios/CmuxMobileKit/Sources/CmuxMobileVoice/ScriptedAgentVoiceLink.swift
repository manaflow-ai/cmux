#if os(iOS) && DEBUG
import CmuxMobileRealtime
import Foundation

/// DEBUG only: voice mode without an OpenAI key or a microphone, for
/// simulator recordings. `CMUX_MOBILE_VOICE_MODE_DEMO=1` turns it on. It
/// answers the session's real client events with the Realtime API's own
/// event shapes: each reading (`response.create`) is "spoken" back as its
/// audio transcript word by word, so the captions show exactly what voice
/// mode chose to say; and once, the user "says" a prompt, which goes to the
/// agent through the real path. Release builds don't contain it.
@MainActor
final class ScriptedAgentVoiceLink: VoiceCallLink {
    let events: AsyncStream<VoiceCallLinkEvent>
    private let sink: AsyncStream<VoiceCallLinkEvent>.Continuation
    private let clock = ContinuousClock()
    private let prompt: String
    private var readings = 0
    private var spokePrompt = false
    private var closed = false

    static func requested(environment: [String: String] = ProcessInfo.processInfo.environment) -> ScriptedAgentVoiceLink? {
        guard let value = environment["CMUX_MOBILE_VOICE_MODE_DEMO"], !value.isEmpty, value != "0" else { return nil }
        let prompt = environment["CMUX_MOBILE_VOICE_MODE_DEMO_PROMPT"] ?? "Run the tests again and tell me what failed."
        return ScriptedAgentVoiceLink(prompt: prompt)
    }

    private init(prompt: String) {
        (events, sink) = AsyncStream.makeStream(of: VoiceCallLinkEvent.self)
        self.prompt = prompt
    }

    func open(session: Data) async throws {
        try await pause(.milliseconds(900)) // the offer/answer, as a real connect takes
        emit(["type": "session.created"])
        Task { [weak self] in await self?.userSpeaks() }
    }

    func send(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "response.create",
              let response = object["response"] as? [String: Any],
              let input = response["input"] as? [[String: Any]],
              let text = (input.first?["content"] as? [[String: Any]])?.first?["text"] as? String else { return }
        Task { [weak self] in await self?.read(text) }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {}
    func setSpeakerOutput(_ speaker: Bool) {}

    func close() {
        closed = true
        sink.finish()
    }

    private func userSpeaks() async {
        guard !closed, !spokePrompt else { return }
        spokePrompt = true
        try? await pause(.milliseconds(1800))
        let itemID = "item_user_0"
        emit(["type": "input_audio_buffer.speech_started", "item_id": itemID])
        for word in words(prompt) {
            try? await pause(.milliseconds(160))
            emit(["type": "conversation.item.input_audio_transcription.delta", "item_id": itemID, "delta": word])
        }
        try? await pause(.milliseconds(400))
        emit(["type": "input_audio_buffer.speech_stopped", "item_id": itemID])
        emit(["type": "conversation.item.input_audio_transcription.completed", "item_id": itemID, "transcript": prompt])
    }

    private func read(_ text: String) async {
        guard !closed else { return }
        readings += 1
        let itemID = "item_agent_\(readings)"
        emit(["type": "response.created", "response": ["id": "resp_\(itemID)"]])
        try? await pause(.milliseconds(350))
        emit(["type": "output_audio_buffer.started"])
        for word in words(text) {
            try? await pause(.milliseconds(150))
            emit(["type": "response.output_audio_transcript.delta", "item_id": itemID, "delta": word])
        }
        emit(["type": "response.output_audio_transcript.done", "item_id": itemID, "transcript": text])
        emit(["type": "response.done", "response": ["status": "completed", "output": []]])
        try? await pause(.milliseconds(400))
        emit(["type": "output_audio_buffer.stopped"])
    }

    private func words(_ text: String) -> [String] {
        text.split(separator: " ").enumerated().map { index, word in index == 0 ? String(word) : " " + word }
    }

    private func emit(_ object: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        sink.yield(.message(data))
    }

    /// Paces the script like real speech (an intentional, bounded delay).
    private func pause(_ duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
#endif
