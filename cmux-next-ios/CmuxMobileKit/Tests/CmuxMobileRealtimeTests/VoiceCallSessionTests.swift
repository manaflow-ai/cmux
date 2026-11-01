import Foundation
import Testing
@testable import CmuxMobileRealtime

/// The link a test drives: server events in through `deliver`, client
/// events out in `sent`.
@MainActor
final class FakeLink: VoiceCallLink {
    let events: AsyncStream<VoiceCallLinkEvent>
    private let sink: AsyncStream<VoiceCallLinkEvent>.Continuation
    var sent: [[String: Any]] = []
    var opened: [Data] = []
    var openFailures: [VoiceCallFailure] = []
    var microphoneEnabled = true
    var speaker = true
    var closed = false

    init() {
        (events, sink) = AsyncStream.makeStream(of: VoiceCallLinkEvent.self)
    }

    func open(session: Data) async throws {
        opened.append(session)
        microphoneEnabled = true // a new connection starts with the microphone on, as WebRTC's does
        if !openFailures.isEmpty { throw openFailures.removeFirst() }
    }

    func send(_ data: Data) {
        sent.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    func setMicrophoneEnabled(_ enabled: Bool) { microphoneEnabled = enabled }
    func setSpeakerOutput(_ speaker: Bool) { self.speaker = speaker }
    func close() { closed = true }

    func deliver(_ json: String) { sink.yield(.message(Data(json.utf8))) }
    func yield(_ event: VoiceCallLinkEvent) { sink.yield(event) }

    var sentTypes: [String] { sent.compactMap { $0["type"] as? String } }
}

@MainActor
final class FakeToolbox: VoiceCallToolbox {
    var sentToChief: [String] = []

    func briefing() -> VoiceCallBriefing {
        VoiceCallBriefing(chiefName: "Chief", chiefStatus: "Runs on Studio")
    }

    func sendToChief(_ message: String) async -> VoiceCallToolResult {
        sentToChief.append(message)
        return VoiceCallToolResult(object: ["status": "sent"], activity: "Sent to Chief: \(message)")
    }

    func readChiefMessages(count: Int) -> VoiceCallToolResult { VoiceCallToolResult(object: ["messages": []]) }
    func listWorkspaces() -> VoiceCallToolResult { VoiceCallToolResult(object: ["workspaces": [["name": "cmux"]]], activity: "Checked workspaces") }
    func listNeedsAttention() -> VoiceCallToolResult { VoiceCallToolResult(object: ["waiting": []]) }
}

/// Lets the session's listener task and tool tasks run.
@MainActor
func settle() async {
    for _ in 0 ..< 20 { await Task.yield() }
}

@MainActor
func liveCall(_ link: FakeLink = FakeLink(), toolbox: FakeToolbox = FakeToolbox()) async -> VoiceCallSession {
    let session = VoiceCallSession(link: link, toolbox: toolbox,
                                   config: VoiceCallSessionConfig(model: "gpt-realtime-2.1", voice: "marin", instructions: "be Chief"))
    await session.start()
    return session
}

@MainActor
@Suite struct VoiceCallSessionTests {
    @Test func connectsWithTheSessionConfig() async throws {
        let link = FakeLink()
        let session = await liveCall(link)
        #expect(session.phase == .live)
        let opened = try #require(link.opened.first)
        let config = try #require(try JSONSerialization.jsonObject(with: opened) as? [String: Any])
        #expect(config["model"] as? String == "gpt-realtime-2.1")
        #expect(config["type"] as? String == "realtime")
        let audio = try #require(config["audio"] as? [String: Any])
        #expect((audio["output"] as? [String: Any])?["voice"] as? String == "marin")
        let input = try #require(audio["input"] as? [String: Any])
        #expect((input["turn_detection"] as? [String: Any])?["interrupt_response"] as? Bool == true)
        let tools = try #require(config["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(VoiceCallTool.Name.allCases.map(\.rawValue)))
    }

    @Test func aServerErrorIsRetriedOnceThenShown() async {
        let link = FakeLink()
        link.openFailures = [.server(status: 500, requestID: "req_1")]
        let session = await liveCall(link)
        #expect(session.phase == .live)
        #expect(link.opened.count == 2)

        let failing = FakeLink()
        failing.openFailures = [.server(status: 500, requestID: "req_1"), .server(status: 502, requestID: "req_2")]
        let failed = await liveCall(failing)
        #expect(failed.phase == .ended(.server(status: 502, requestID: "req_2")))
        #expect(failing.opened.count == 2)
    }

    @Test func rejectedKeyEndsTheCallWithThatReason() async {
        let link = FakeLink()
        link.openFailures = [.keyRejected]
        let session = await liveCall(link)
        #expect(session.phase == .ended(.keyRejected))
        #expect(link.closed)
    }

    @Test func refusedTranscriptionModelRetriesWithTheOlderOne() async throws {
        let link = FakeLink()
        link.openFailures = [.refused("Invalid value for audio.input.transcription.model")]
        let session = await liveCall(link)
        #expect(session.phase == .live)
        #expect(link.opened.count == 2)
        let second = try #require(try JSONSerialization.jsonObject(with: link.opened[1]) as? [String: Any])
        let input = (second["audio"] as? [String: Any])?["input"] as? [String: Any]
        #expect((input?["transcription"] as? [String: Any])?["model"] as? String == VoiceCallSessionConfig.fallbackTranscriptionModel)
    }

    @Test func captionsFollowSpeechAndTranscripts() async {
        let link = FakeLink()
        let session = await liveCall(link)
        link.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"u1"}"#)
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"What's "}"#)
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"running?"}"#)
        await settle()
        #expect(session.userSpeaking)
        link.deliver(#"{"type":"input_audio_buffer.speech_stopped","item_id":"u1"}"#)
        link.deliver(#"{"type":"response.created","response":{"id":"r1"}}"#)
        link.deliver(#"{"type":"output_audio_buffer.started"}"#)
        link.deliver(#"{"type":"response.output_audio_transcript.delta","item_id":"a1","delta":"Two agents"}"#)
        await settle()
        #expect(!session.userSpeaking)
        #expect(session.chiefSpeaking)
        link.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"What's running?"}"#)
        link.deliver(#"{"type":"response.output_audio_transcript.done","item_id":"a1","transcript":"Two agents are working."}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)
        link.deliver(#"{"type":"output_audio_buffer.stopped"}"#)
        await settle()
        #expect(session.lines.map(\.text) == ["What's running?", "Two agents are working."])
        #expect(session.lines.map(\.role) == [.you, .chief])
        #expect(session.lines.allSatisfy { $0.isFinal })
        #expect(!session.chiefSpeaking)
    }

    @Test func sendToChiefRunsAndTheModelContinues() async {
        let link = FakeLink()
        let toolbox = FakeToolbox()
        let session = await liveCall(link, toolbox: toolbox)
        link.deliver(#"""
        {"type":"response.done","response":{"status":"completed","output":[{"type":"function_call","call_id":"c1","name":"send_to_chief","arguments":"{\"message\":\"Run the iOS tests\"}"}]}}
        """#)
        await settle()
        #expect(toolbox.sentToChief == ["Run the iOS tests"])
        let output = link.sent.first { $0["type"] as? String == "conversation.item.create" }?["item"] as? [String: Any]
        #expect(output?["type"] as? String == "function_call_output")
        #expect(output?["call_id"] as? String == "c1")
        #expect(link.sentTypes.last == "response.create")
        #expect(session.lines.last?.role == .activity)
        #expect(session.lines.last?.text == "Sent to Chief: Run the iOS tests")
    }

    @Test func endCallHangsUpAfterTheGoodbyePlays() async {
        let link = FakeLink()
        let session = await liveCall(link)
        link.deliver(#"{"type":"output_audio_buffer.started"}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"completed","output":[{"type":"function_call","call_id":"c9","name":"end_call","arguments":"{}"}]}}"#)
        await settle()
        #expect(session.isLive)
        #expect(!link.sentTypes.contains("response.create"))
        link.deliver(#"{"type":"output_audio_buffer.stopped"}"#)
        await settle()
        #expect(session.phase == .ended(nil))
        #expect(link.closed)
    }

    @Test func chiefRepliesWaitWhileTheUserTalks() async {
        let link = FakeLink()
        let session = await liveCall(link)
        link.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"u2"}"#)
        await settle()
        session.chiefReplied("Tests passed: 412 of 412.")
        #expect(!link.sentTypes.contains("response.create"))
        link.deliver(#"{"type":"input_audio_buffer.speech_stopped","item_id":"u2"}"#)
        link.deliver(#"{"type":"response.created"}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)
        await settle()
        let note = link.sent.first { ($0["item"] as? [String: Any])?["role"] as? String == "system" }
        let content = ((note?["item"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(content == "Chief replied: Tests passed: 412 of 412.")
        #expect(link.sentTypes.last == "response.create")
    }

    @Test func tapToInterruptCancelsAndClearsAudio() async {
        let link = FakeLink()
        let session = await liveCall(link)
        link.deliver(#"{"type":"response.created"}"#)
        link.deliver(#"{"type":"output_audio_buffer.started"}"#)
        await settle()
        session.interrupt()
        #expect(link.sentTypes.suffix(2) == ["response.cancel", "output_audio_buffer.clear"])
        #expect(!session.chiefSpeaking)
    }

    @Test func typedMessageIsAUserTurn() async {
        let link = FakeLink()
        let session = await liveCall(link)
        session.send(text: "  Open a PR for the fix  ")
        let item = link.sent.first?["item"] as? [String: Any]
        #expect(item?["role"] as? String == "user")
        #expect(((item?["content"] as? [[String: Any]])?.first?["text"]) as? String == "Open a PR for the fix")
        #expect(link.sentTypes == ["conversation.item.create", "response.create"])
        #expect(session.lines.last?.role == .you)
    }

    @Test func muteAndHoldGateTheMicrophone() async {
        let link = FakeLink()
        let session = await liveCall(link)
        session.setMuted(true)
        #expect(!link.microphoneEnabled)
        session.setMuted(false)
        #expect(link.microphoneEnabled)
        link.yield(.audioInterrupted(true))
        await settle()
        #expect(session.onHold)
        #expect(!link.microphoneEnabled)
        link.yield(.audioInterrupted(false))
        await settle()
        #expect(link.microphoneEnabled)
    }

    @Test func typingDuringAReplyStartsExactlyOneResponse() async {
        let link = FakeLink()
        let session = await liveCall(link)
        link.deliver(#"{"type":"response.created"}"#)
        link.deliver(#"{"type":"output_audio_buffer.started"}"#)
        await settle()
        session.send(text: "Actually, stop the build")
        // The cancelled reply ends before the typed turn's response starts.
        link.deliver(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#)
        await settle()
        session.chiefReplied("Build stopped.")
        #expect(link.sentTypes.filter { $0 == "response.create" }.count == 1)
        link.deliver(#"{"type":"response.created"}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)
        await settle()
        #expect(link.sentTypes.filter { $0 == "response.create" }.count == 2)
        #expect(link.sent.contains { ($0["item"] as? [String: Any])?["role"] as? String == "system" })
    }

    @Test func aRefusedResponseCreateIsAskedAgain() async {
        let link = FakeLink()
        let session = await liveCall(link)
        session.chiefReplied("PR #42 is open.")
        #expect(link.sentTypes.filter { $0 == "response.create" }.count == 1)
        // The server had just started its own response (the user spoke): ours is refused.
        link.deliver(#"{"type":"error","error":{"type":"invalid_request_error","code":"conversation_already_has_active_response","message":"active response"}}"#)
        link.deliver(#"{"type":"response.created"}"#)
        link.deliver(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)
        await settle()
        #expect(link.sentTypes.filter { $0 == "response.create" }.count == 2)
    }

    @Test func muteSetWhileConnectingHolds() async {
        let link = FakeLink()
        let session = VoiceCallSession(link: link, toolbox: FakeToolbox(),
                                       config: VoiceCallSessionConfig(model: "gpt-realtime-2.1", voice: "marin", instructions: ""))
        session.setMuted(true)
        await session.start()
        #expect(session.isLive)
        #expect(!link.microphoneEnabled)
    }

    @Test func endingReportsOnceWithTheReason() async {
        let link = FakeLink()
        let session = await liveCall(link)
        var ends: [VoiceCallFailure?] = []
        session.onEnd = { ends.append($0) }
        link.yield(.closed)
        await settle()
        session.hangUp()
        #expect(ends == [.dropped])
    }

    @Test func droppedConnectionEndsTheCall() async {
        let link = FakeLink()
        let session = await liveCall(link)
        link.yield(.closed)
        await settle()
        #expect(session.phase == .ended(.dropped))
    }
}

@Suite struct RealtimeAPITests {
    struct StubHTTP: VoiceCallHTTP {
        let status: Int
        let body: String
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    struct HeaderHTTP: VoiceCallHTTP {
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data("Internal Server Error".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: ["x-request-id": "req_abc"])!)
        }
    }

    @Test func aBare500CarriesItsRequestID() async {
        await #expect(throws: VoiceCallFailure.server(status: 500, requestID: "req_abc")) {
            _ = try await RealtimeCallsAPI(http: HeaderHTTP()).connect(offerSDP: "v=0", session: Data(), apiKey: "sk-x", safetyIdentifier: nil)
        }
    }

    @Test func answerSDPComesBack() async throws {
        let api = RealtimeCallsAPI(http: StubHTTP(status: 201, body: "v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n"))
        let answer = try await api.connect(offerSDP: "v=0", session: Data("{}".utf8), apiKey: "sk-test", safetyIdentifier: nil)
        #expect(answer.hasPrefix("v=0"))
    }

    @Test func errorsMapToCallFailures() async {
        let cases: [(Int, String, VoiceCallFailure)] = [
            (401, #"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#, .keyRejected),
            (404, #"{"error":{"message":"The model does not exist"}}"#, .modelUnavailable("The model does not exist")),
            (400, #"{"error":{"message":"bad session"}}"#, .refused("bad session")),
        ]
        for (status, body, expected) in cases {
            let api = RealtimeCallsAPI(http: StubHTTP(status: status, body: body))
            await #expect(throws: expected) {
                _ = try await api.connect(offerSDP: "v=0", session: Data(), apiKey: "sk-x", safetyIdentifier: nil)
            }
        }
    }

    @Test func multipartCarriesSDPAndSession() {
        let body = String(decoding: RealtimeCallsAPI.multipart(boundary: "b", fields: [("sdp", "application/sdp", Data("v=0".utf8)),
                                                                                       ("session", "application/json", Data("{}".utf8))]),
                          as: UTF8.self)
        #expect(body.contains("name=\"sdp\"\r\nContent-Type: application/sdp\r\n\r\nv=0\r\n"))
        #expect(body.hasSuffix("--b--\r\n"))
    }

    @MainActor
    @Test func keyModelStoresOnlyKeysOpenAIAccepts() async {
        final class MemoryStore: OpenAIKeyStoring, @unchecked Sendable {
            var value: String?
            func load() -> String? { value }
            func save(_ key: String) throws { value = key }
            func delete() throws { value = nil }
        }
        let store = MemoryStore()
        let rejecting = OpenAIKeyModel(makeStore: { _ in store }, verifier: OpenAIKeyVerifier(http: StubHTTP(status: 401, body: "")))
        rejecting.selectAccount("user-1")
        #expect(await rejecting.add("sk-proj-abcdefghijklmnop1234", model: "gpt-realtime-2.1") == .rejected)
        #expect(!rejecting.hasKey)
        #expect(await rejecting.add("not a key", model: "gpt-realtime-2.1") == .malformed)

        let accepting = OpenAIKeyModel(makeStore: { _ in store }, verifier: OpenAIKeyVerifier(http: StubHTTP(status: 200, body: "{}")))
        accepting.selectAccount("user-1")
        #expect(await accepting.add(" sk-proj-abcdefghijklmnop1234\n", model: "gpt-realtime-2.1") == .valid)
        #expect(accepting.hasKey)
        #expect(accepting.maskedKey == "sk-…1234")
        #expect(store.value == "sk-proj-abcdefghijklmnop1234")
        accepting.remove()
        #expect(!accepting.hasKey)
    }
}
