import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite("VoiceLiveEvents")
struct VoiceLiveEventsTests {
    private func encode(_ event: VoiceLiveClientEvent) throws -> [String: Any] {
        let data = try event.jsonData(eventID: "evt_test")
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("session.start encodes model, audio format, voice, and client delegation")
    func sessionStartClientDelegation() throws {
        let config = VoiceLiveSessionConfig(
            model: "gpt-live-1",
            voice: "marin",
            instructions: "Be brief.",
            delegation: .client
        )
        let payload = try encode(.sessionStart(config))
        #expect(payload["type"] as? String == "session.start")
        #expect(payload["event_id"] as? String == "evt_test")
        let session = try #require(payload["session"] as? [String: Any])
        #expect(session["model"] as? String == "gpt-live-1")
        #expect(session["instructions"] as? String == "Be brief.")
        let audio = try #require(session["audio"] as? [String: Any])
        let format = try #require(audio["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        let output = try #require(audio["output"] as? [String: Any])
        #expect(output["voice"] as? String == "marin")
        let delegation = try #require(session["delegation"] as? [String: Any])
        #expect(delegation["type"] as? String == "client")
    }

    @Test("session.start encodes responses delegation with function tools")
    func sessionStartResponsesDelegation() throws {
        let tool = VoiceLiveTool(
            name: "list_workspaces",
            description: "List workspaces",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#
        )
        let config = VoiceLiveSessionConfig(
            model: "gpt-live-1",
            voice: "stone",
            instructions: "x",
            delegation: .responses(model: "gpt-5.6-terra", instructions: "backend", tools: [tool])
        )
        let payload = try encode(.sessionStart(config))
        let session = try #require(payload["session"] as? [String: Any])
        let delegation = try #require(session["delegation"] as? [String: Any])
        #expect(delegation["type"] as? String == "responses")
        let responses = try #require(delegation["responses"] as? [String: Any])
        #expect(responses["model"] as? String == "gpt-5.6-terra")
        #expect(responses["tool_choice"] as? String == "auto")
        // Serial calls keep the approval gate's one-output-then-continue
        // contract sound.
        #expect(responses["parallel_tool_calls"] as? Bool == false)
        let tools = try #require(responses["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "list_workspaces")
        let parameters = try #require(tools[0]["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
    }

    @Test("input audio appends base64 PCM")
    func inputAudioAppend() throws {
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        let payload = try encode(.inputAudioAppend(audio))
        #expect(payload["type"] as? String == "session.input_audio.append")
        #expect(payload["audio"] as? String == audio.base64EncodedString())
    }

    @Test("context appends carry content and nullable delegation id")
    func contextAppends() throws {
        let commentary = try encode(.commentaryAppend(text: "say this", delegationID: "item_1"))
        #expect(commentary["type"] as? String == "session.commentary.append")
        #expect(commentary["content"] as? String == "say this")
        #expect(commentary["delegation_id"] as? String == "item_1")

        let thinking = try encode(.thinkingAppend(text: "note", delegationID: nil))
        #expect(thinking["type"] as? String == "session.thinking.append")
        #expect(thinking["delegation_id"] is NSNull)
    }

    @Test("function call output pairs with response.create")
    func functionCallOutput() throws {
        let payload = try encode(.functionCallOutput(callID: "call_9", output: "{\"ok\":true}"))
        #expect(payload["type"] as? String == "response.item.create")
        let item = try #require(payload["item"] as? [String: Any])
        #expect(item["type"] as? String == "function_call_output")
        #expect(item["call_id"] as? String == "call_9")
        #expect(item["output"] as? String == "{\"ok\":true}")

        let create = try encode(.responseCreate)
        #expect(create["type"] as? String == "response.create")
    }

    private func parse(_ json: String) -> VoiceLiveServerEvent? {
        VoiceLiveServerEvent.parse(Data(json.utf8))
    }

    @Test("parses session.started")
    func parseStarted() {
        let event = parse(#"{"type":"session.started","session":{"id":"live_123"}}"#)
        #expect(event == .started(sessionID: "live_123"))
    }

    @Test("parses output audio deltas from base64")
    func parseAudioDelta() {
        let audio = Data([0x0A, 0x0B, 0x0C, 0x0D])
        let event = parse(
            #"{"type":"session.output_audio.delta","delta":"\#(audio.base64EncodedString())"}"#
        )
        #expect(event == .outputAudioDelta(audio))
    }

    @Test("parses transcript deltas for both directions")
    func parseTranscripts() {
        #expect(
            parse(#"{"type":"session.input_transcript.delta","delta":"hello"}"#)
                == .inputTranscriptDelta("hello")
        )
        #expect(
            parse(#"{"type":"session.output_transcript.delta","delta":"hi"}"#)
                == .outputTranscriptDelta("hi")
        )
    }

    @Test("parses client delegation creation")
    func parseDelegation() {
        let event = parse(
            #"{"type":"session.delegation.created","delegation":{"id":"item_9","type":"delegation","target":"client"}}"#
        )
        #expect(event == .delegationCreated(id: "item_9", target: "client"))
    }

    @Test("extracts completed function calls from the response.event envelope")
    func parseFunctionCall() {
        let json = """
        {"type":"response.event","delegation_id":"item_2","event":{
          "type":"response.output_item.done",
          "item":{"type":"function_call","call_id":"call_3","name":"send_prompt",
                  "arguments":"{\\"workspace\\":\\"api\\"}"}}}
        """
        let event = parse(json)
        #expect(event == .functionCall(
            callID: "call_3",
            name: "send_prompt",
            argumentsJSON: #"{"workspace":"api"}"#,
            delegationID: "item_2"
        ))
    }

    @Test("other response envelope events do not become function calls")
    func parseOtherResponseEvents() {
        let json = """
        {"type":"response.event","delegation_id":"item_2","event":{
          "type":"response.output_text.delta","delta":"partial"}}
        """
        let event = parse(json)
        #expect(event == .other(type: "response.event:response.output_text.delta"))
    }

    @Test("parses errors and close events")
    func parseErrorAndClose() {
        #expect(
            parse(#"{"type":"error","error":{"code":"bad_request","message":"nope"}}"#)
                == .errorEvent(code: "bad_request", message: "nope")
        )
        #expect(
            parse(#"{"type":"session.closed","reason":"close_requested"}"#)
                == .closed(reason: "close_requested")
        )
    }

    @Test("unknown event types map to other, non-JSON frames to nil")
    func parseUnknown() {
        #expect(parse(#"{"type":"session.future.thing"}"#) == .other(type: "session.future.thing"))
        #expect(parse("not json") == nil)
        #expect(parse(#"["array"]"#) == nil)
    }
}
