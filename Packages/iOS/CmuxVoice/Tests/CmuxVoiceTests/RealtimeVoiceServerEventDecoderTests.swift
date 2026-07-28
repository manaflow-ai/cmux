import Foundation
import Testing
@testable import CmuxVoice

@Suite struct RealtimeVoiceServerEventDecoderTests {
    private let decoder = RealtimeVoiceServerEventDecoder()

    @Test func decodesAudioAndTranscriptEvents() throws {
        let audio = Data([0, 1, 2, 3])
        #expect(decode(#"{"type":"session.created"}"#) == .sessionReady)
        #expect(decode(#"{"type":"input_audio_buffer.committed","item_id":"item-1"}"#) == .inputCommitted(itemID: "item-1"))
        #expect(decode(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","delta":"hello"}"#) == .inputTranscriptDelta(itemID: "item-1", delta: "hello"))
        #expect(decode(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"hello world"}"#) == .inputTranscriptCompleted(itemID: "item-1", transcript: "hello world"))
        #expect(decode(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"item-2"}"#) == .inputTranscriptFailed(itemID: "item-2"))
        #expect(decode(#"{"type":"response.output_audio.delta","item_id":"assistant-1","delta":"AAECAw=="}"#) == .outputAudioDelta(itemID: "assistant-1", data: audio))
        #expect(decode(#"{"type":"response.output_audio_transcript.delta","delta":"done"}"#) == .outputTranscriptDelta("done"))
        #expect(decode(#"{"type":"input_audio_buffer.speech_started"}"#) == .speechStarted)
    }

    @Test func decodesOnlyTheConstrainedFunctionToolSurface() throws {
        #expect(
            decode(#"{"type":"response.created","response":{"id":"response-1"}}"#)
                == .responseCreated(responseID: "response-1")
        )
        let event = try #require(decode(
            #"{"type":"response.done","response":{"id":"response-1","output":[{"type":"function_call","call_id":"call-1","name":"send_latest_utterance","arguments":"{\"target_ids\":[\"terminal-2\",\"terminal-2\",\"terminal-3\"]}"}]}}"#
        ))
        guard case .responseDone(let responseID, let calls) = event else {
            Issue.record("Expected response.done")
            return
        }
        #expect(responseID == "response-1")
        let call = try #require(calls.first)
        #expect(call.decodedToolCall() == .sendLatestUtterance(targetIDs: ["terminal-2", "terminal-3"]))

        let unknown = RealtimeVoiceFunctionCall(
            callID: "call-2",
            name: "run_shell_command",
            arguments: #"{"command":"rm -rf /"}"#
        )
        #expect(unknown.decodedToolCall() == nil)
    }

    @Test func rejectsOversizedOrMalformedEvents() {
        #expect(decoder.decode(Data("not-json".utf8)) == nil)
        #expect(decoder.decode(Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1)) == nil)
        #expect(decode(#"{"type":"response.output_audio.delta","item_id":"x","delta":"not-base64"}"#) == nil)
    }

    private func decode(_ json: String) -> RealtimeVoiceServerEvent? {
        decoder.decode(Data(json.utf8))
    }
}
