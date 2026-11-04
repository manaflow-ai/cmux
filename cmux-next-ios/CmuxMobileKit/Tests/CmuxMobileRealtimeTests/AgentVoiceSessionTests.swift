import Foundation
import Testing
@testable import CmuxMobileRealtime

@MainActor
func liveVoice(_ link: FakeLink = FakeLink()) async -> AgentVoiceSession {
    let session = AgentVoiceSession(link: link, config: AgentVoiceSessionConfig(model: "gpt-realtime-2.1", voice: "marin", agentName: "Claude"))
    await session.start()
    await settle()
    return session
}

/// The text of each reading voice mode asked for (out-of-band `response.create`).
@MainActor
func readings(_ link: FakeLink) -> [String] {
    link.sent.compactMap { event in
        guard event["type"] as? String == "response.create",
              let response = event["response"] as? [String: Any],
              let input = response["input"] as? [[String: Any]],
              let content = input.first?["content"] as? [[String: Any]] else { return nil }
        return content.first?["text"] as? String
    }
}

@MainActor
@Suite struct AgentVoiceSessionTests {
    @Test func theSessionNeverAnswersSpeechOnItsOwn() throws {
        let config = AgentVoiceSessionConfig(model: "gpt-realtime-2.1", voice: "cedar", agentName: "Codex")
        let session = try #require(try JSONSerialization.jsonObject(with: config.json) as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let turns = try #require(input["turn_detection"] as? [String: Any])
        #expect(turns["create_response"] as? Bool == false)
        #expect(turns["interrupt_response"] as? Bool == true)
        #expect((session["tools"] as? [Any])?.isEmpty == true)
        #expect(session["model"] as? String == "gpt-realtime-2.1")
        #expect((audio["output"] as? [String: Any])?["voice"] as? String == "cedar")
    }

    @Test func agentWordsAreReadOutOfBandVerbatim() async throws {
        let link = FakeLink()
        let session = await liveVoice(link)
        session.relay("All 43 tests pass.")
        #expect(readings(link) == ["All 43 tests pass."])
        let event = try #require(link.sent.last)
        let response = try #require(event["response"] as? [String: Any])
        #expect(response["conversation"] as? String == "none")
        #expect((response["instructions"] as? String)?.contains("word for word") == true)
    }

    @Test func readingsQueueInOrderOneAtATime() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        session.relay("First.")
        session.relay("Second.")
        session.relay("Third.")
        // One reading in flight; the rest wait and go out together, in order.
        #expect(readings(link) == ["First."])
        link.deliver(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)
        await settle()
        #expect(readings(link) == ["First.", "Second.\n\nThird."])
    }

    @Test func nothingIsReadOverTheUser() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        link.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"u1"}"#)
        await settle()
        session.relay("The build finished.")
        #expect(readings(link).isEmpty)
        link.deliver(#"{"type":"input_audio_buffer.speech_stopped","item_id":"u1"}"#)
        await settle()
        #expect(readings(link) == ["The build finished."])
    }

    @Test func whatTheUserSaysGoesToTheAgent() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        var prompts: [String] = []
        session.onUserSaid = { prompts.append($0) }
        link.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"u1"}"#)
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"Run the"}"#)
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"Run the tests again."}"#)
        await settle()
        #expect(prompts == ["Run the tests again."])
        #expect(session.lines.last == AgentVoiceLine(id: "u1", role: .you, text: "Run the tests again.", isFinal: true))
        // The model is never asked to answer the user itself.
        #expect(readings(link).isEmpty)
        #expect(!link.sentTypes.contains("response.create"))
    }

    @Test func aRefusedReadingIsSaidAgain() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        session.relay("Needs your permission: Run make.")
        link.deliver(#"{"type":"error","error":{"code":"conversation_already_has_active_response","message":"busy"}}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)
        await settle()
        #expect(readings(link) == ["Needs your permission: Run make.", "Needs your permission: Run make."])
    }

    @Test func skipStopsTheVoiceAndDropsTheQueue() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        session.relay("One.")
        session.relay("Two.")
        session.skip()
        #expect(link.sentTypes.suffix(2) == ["response.cancel", "output_audio_buffer.clear"])
        link.deliver(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#)
        await settle()
        #expect(readings(link) == ["One."])
    }

    @Test func endingClosesTheLinkAndReportsOnce() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        var ends: [VoiceCallFailure?] = []
        session.onEnd = { ends.append($0) }
        session.end()
        session.end()
        #expect(link.closed)
        #expect(ends.count == 1)
        session.relay("Too late.")
        #expect(readings(link).isEmpty)
    }

    @Test func aDroppedConnectionEndsWithDropped() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        link.yield(.closed)
        await settle()
        #expect(session.phase == .ended(.dropped))
    }

    @Test func textRelayedWhileConnectingIsReadOnceLive() async {
        let link = FakeLink()
        let session = AgentVoiceSession(link: link, config: AgentVoiceSessionConfig(model: "m", voice: "marin", agentName: "Claude"))
        session.relay("Early words.")
        await session.start()
        #expect(readings(link) == ["Early words."])
    }
}

/// The review's findings (2026-11-03), each kept from coming back.
@MainActor
@Suite struct AgentVoiceSessionRecoveryTests {
    @Test func noiseIsNeverSentAsAPrompt() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        var prompts: [String] = []
        session.onUserSaid = { prompts.append($0) }
        for (index, noise) in ["Thank you.", "  ", "Bye!", "Hmm…", "you"].enumerated() {
            link.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"n\#(index)","transcript":"\#(noise)"}"#)
        }
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"Yes, go ahead."}"#)
        await settle()
        #expect(prompts == ["Yes, go ahead."])
        #expect(session.lines.map(\.id) == ["u1"])
    }

    @Test func aReadingRefusedForAnotherReasonDoesNotStallVoiceMode() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        session.relay("First.")
        session.relay("Second.")
        // A rate limit refuses our response.create: no response.created, no response.done.
        link.deliver(#"{"type":"error","error":{"code":"rate_limit_exceeded","message":"slow down"}}"#)
        await settle()
        // Retried once, with what was queued behind it.
        #expect(readings(link) == ["First.", "First.\n\nSecond."])
        link.deliver(#"{"type":"error","error":{"code":"rate_limit_exceeded","message":"slow down"}}"#)
        await settle()
        // Refused again: dropped, and voice mode goes on with what comes next.
        session.relay("Third.")
        #expect(readings(link).last == "Third.")
    }

    @Test func aReadingCutOffByNoiseIsSaidAgain() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        session.relay("Needs your permission: Run make.")
        link.deliver(#"{"type":"response.created","response":{"id":"r1"}}"#)
        link.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"c1"}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#)
        link.deliver(#"{"type":"input_audio_buffer.speech_stopped","item_id":"c1"}"#)
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"c1","transcript":"Hmm."}"#)
        await settle()
        #expect(readings(link) == ["Needs your permission: Run make.", "Needs your permission: Run make."])
    }

    @Test func aReadingCutOffByARealPromptIsNotRepeated() async {
        let link = FakeLink()
        let session = await liveVoice(link)
        session.relay("Here is a long answer.")
        link.deliver(#"{"type":"response.created","response":{"id":"r1"}}"#)
        link.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"u1"}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#)
        link.deliver(#"{"type":"input_audio_buffer.speech_stopped","item_id":"u1"}"#)
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"Stop, do the other thing."}"#)
        await settle()
        #expect(readings(link) == ["Here is a long answer."])
    }
}
