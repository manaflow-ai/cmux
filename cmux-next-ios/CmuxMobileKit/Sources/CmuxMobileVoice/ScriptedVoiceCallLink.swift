#if os(iOS) && DEBUG
import CmuxMobileRealtime
import Foundation

/// DEBUG only: a Chief call that plays a scripted conversation through the
/// real call session, tools and screen, for simulator recordings without an
/// OpenAI key or a microphone. `CMUX_MOBILE_CALL_DEMO=1` turns it on;
/// `CMUX_MOBILE_CALL_DEMO=hold` keeps the call open at the end instead of
/// saying goodbye. The server events are the Realtime API's own (same JSON
/// shapes); the tool outputs come from the app's real toolbox, and a
/// send_to_chief really sends to Chief, whose reply comes back through the
/// app's Chief watcher. Release and Production builds don't contain it.
@MainActor
final class ScriptedVoiceCallLink: VoiceCallLink {
    let events: AsyncStream<VoiceCallLinkEvent>
    private let sink: AsyncStream<VoiceCallLinkEvent>.Continuation
    private let holdAtEnd: Bool
    private let clock = ContinuousClock()
    private var step = 0
    private var turn = 0
    private var closed = false

    static func requested(environment: [String: String] = ProcessInfo.processInfo.environment) -> ScriptedVoiceCallLink? {
        guard let value = environment["CMUX_MOBILE_CALL_DEMO"], !value.isEmpty, value != "0" else { return nil }
        return ScriptedVoiceCallLink(holdAtEnd: value == "hold")
    }

    private init(holdAtEnd: Bool) {
        (events, sink) = AsyncStream.makeStream(of: VoiceCallLinkEvent.self)
        self.holdAtEnd = holdAtEnd
    }

    func open(session: Data) async throws {
        try await pause(.milliseconds(1400)) // the HTTPS offer/answer and DTLS, as a real call takes
        emit(["type": "session.created"])
        Task { [weak self] in await self?.userTurn() }
    }

    func send(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        let item = object["item"] as? [String: Any]
        switch type {
        case "conversation.item.create" where item?["type"] as? String == "function_call_output":
            lastToolOutput = item?["output"] as? String
        case "conversation.item.create" where item?["role"] as? String == "user":
            lastTyped = ((item?["content"] as? [[String: Any]])?.first?["text"] as? String)
        case "conversation.item.create" where item?["role"] as? String == "system":
            lastNote = ((item?["content"] as? [[String: Any]])?.first?["text"] as? String)
        case "response.create":
            Task { [weak self] in await self?.respond() }
        default:
            break
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {}
    func setSpeakerOutput(_ speaker: Bool) {}

    func close() {
        closed = true
        sink.finish()
    }

    private var lastToolOutput: String?
    private var lastNote: String?
    private var lastTyped: String?

    private let userLines = [
        "Hey Chief, what's going on across my workspaces right now?",
        "Ask Chief to run the simulator tests on the call branch and tell me when they pass.",
    ]

    /// The user's next scripted turn: speech, its transcript, then the model's first move.
    private func userTurn() async {
        guard !closed, turn < userLines.count else { return }
        let line = userLines[turn]
        let itemID = "item_user_\(turn)"
        turn += 1
        try? await pause(.milliseconds(900))
        emit(["type": "input_audio_buffer.speech_started", "item_id": itemID])
        for word in words(line) {
            try? await pause(.milliseconds(170))
            emit(["type": "conversation.item.input_audio_transcription.delta", "item_id": itemID, "delta": word])
        }
        try? await pause(.milliseconds(500))
        emit(["type": "input_audio_buffer.speech_stopped", "item_id": itemID])
        emit(["type": "conversation.item.input_audio_transcription.completed", "item_id": itemID, "transcript": line])
        emit(["type": "response.created", "response": ["id": "resp_\(itemID)"]])
        try? await pause(.milliseconds(700))
        let call: [String: Any] = turn == 1
            ? ["type": "function_call", "call_id": "call_ws", "name": "list_workspaces", "arguments": "{}"]
            : ["type": "function_call", "call_id": "call_send", "name": "send_to_chief",
               "arguments": #"{"message":"Run the iOS simulator tests on the feat-cmux-next-call-chief branch and tell me when they pass."}"#]
        emit(["type": "response.done", "response": ["status": "completed", "output": [call]]])
    }

    /// The model answers after a tool output or a Chief reply.
    private func respond() async {
        guard !closed else { return }
        step += 1
        let text: String
        var then: (() async -> Void)?
        if let typed = lastTyped {
            lastTyped = nil
            text = "Got it. You wrote: \(typed). Want me to send that to Chief?"
        } else if let note = lastNote {
            lastNote = nil
            let reply = note.replacingOccurrences(of: "Chief replied: ", with: "")
            text = "Chief just replied. It says: \(reply.prefix(160))"
            if !holdAtEnd { then = { [weak self] in await self?.goodbye() } }
        } else if step == 1 {
            text = workspaceSummary()
            then = { [weak self] in await self?.userTurn() }
        } else {
            text = "Done. I've asked Chief to run the simulator tests on that branch. I'll tell you as soon as it answers."
        }
        try? await speak(text, itemID: "item_chief_\(step)")
        await then?()
    }

    private func goodbye() async {
        try? await pause(.milliseconds(1600))
        let itemID = "item_user_bye"
        emit(["type": "input_audio_buffer.speech_started", "item_id": itemID])
        try? await pause(.milliseconds(600))
        emit(["type": "input_audio_buffer.speech_stopped", "item_id": itemID])
        emit(["type": "conversation.item.input_audio_transcription.completed", "item_id": itemID, "transcript": "Perfect, thanks. Bye!"])
        emit(["type": "response.created", "response": ["id": "resp_bye"]])
        emit(["type": "output_audio_buffer.started"])
        for word in words("Talk soon!") {
            try? await pause(.milliseconds(160))
            emit(["type": "response.output_audio_transcript.delta", "item_id": "item_chief_bye", "delta": word])
        }
        emit(["type": "response.output_audio_transcript.done", "item_id": "item_chief_bye", "transcript": "Talk soon!"])
        emit(["type": "response.done", "response": ["status": "completed", "output": [
            ["type": "function_call", "call_id": "call_end", "name": "end_call", "arguments": "{}"],
        ]]])
        try? await pause(.milliseconds(900))
        emit(["type": "output_audio_buffer.stopped"])
    }

    private func speak(_ text: String, itemID: String) async throws {
        emit(["type": "response.created", "response": ["id": "resp_\(itemID)"]])
        try await pause(.milliseconds(450))
        emit(["type": "output_audio_buffer.started"])
        for word in words(text) {
            try await pause(.milliseconds(190))
            emit(["type": "response.output_audio_transcript.delta", "item_id": itemID, "delta": word])
        }
        emit(["type": "response.output_audio_transcript.done", "item_id": itemID, "transcript": text])
        emit(["type": "response.done", "response": ["status": "completed", "output": []]])
        try await pause(.milliseconds(600))
        emit(["type": "output_audio_buffer.stopped"])
    }

    /// What the real list_workspaces output says, as the model would put it.
    private func workspaceSummary() -> String {
        let object = lastToolOutput.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let lines = object?["workspaces"] as? [String] ?? []
        let total = object?["total"] as? Int ?? lines.count
        guard let first = lines.first else { return "I don't see any workspaces on your Macs yet." }
        let name = first.split(separator: ";").first.map(String.init) ?? first
        let busy = lines.filter { $0.contains("working") }.count
        return "You have \(total) workspaces. \(busy) of them have agents working, and the most recent is \(name). Want me to have Chief do anything?"
    }

    private func words(_ text: String) -> [String] {
        var out: [String] = []
        for (index, word) in text.split(separator: " ").enumerated() {
            out.append(index == 0 ? String(word) : " " + word)
        }
        return out
    }

    private func emit(_ object: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        sink.yield(.message(data))
    }

    /// Paces the script like a real conversation (an intentional, bounded delay).
    private func pause(_ duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
#endif
