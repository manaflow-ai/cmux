import Foundation
import Testing
import CmuxNextSettings
import CmuxNextDictation
@testable import CmuxNextAgentPane

@Suite struct AgentPaneVoiceWireTests {
    private func chunk(session: String = "s", sequence: Int = 1, kind: String = "agent_message_chunk", text: String = "Hello") -> String {
        let value: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
            "params": .object(["sessionId": .string(session),
                "_meta": .object(["acpmux": .object(["seq": .number(Double(sequence))])]),
                "update": .object(["sessionUpdate": .string(kind), "messageId": .string("m"),
                    "content": .object(["type": .string("text"), "text": .string(text)])])])])
        return value.compactText
    }
    @Test func onlyLiveAssistantTextIsForwardedAndMirroredSequencesAreDeduplicated() {
        var wire = AgentPaneVoiceWire()
        #expect(wire.receive(#"{"jsonrpc":"2.0","id":1,"result":{"events":[{"kind":"agent_message_chunk"}]}}"#, session: "s").isEmpty)
        #expect(wire.receive(chunk(session: "other"), session: "s").isEmpty)
        #expect(wire.receive(chunk(kind: "agent_thought_chunk"), session: "s").isEmpty)
        let text = wire.receive(chunk(sequence: 2), session: "s")
        #expect(text == [.init(id: "m:0", text: "Hello", done: false)])
        #expect(wire.receive(chunk(sequence: 2), session: "s").isEmpty)
        let tool = #"{"method":"_acpmux/event","params":{"sessionId":"s","seq":3,"kind":"tool_call","msg":{"content":"do not speak me"}}}"#
        #expect(wire.receive(tool, session: "s") == [.init(id: "m:0", text: "", done: true)])
        #expect(wire.receive(chunk(sequence: 1), session: "s").isEmpty)
    }
    @Test func canonicalNotificationsFlushAtTurnEndAndNeverReadToolResults() {
        var wire = AgentPaneVoiceWire()
        let canonical = #"{"method":"_acpmux/event","params":{"sessionId":"s","seq":4,"kind":"agent_message_chunk","msg":{"params":{"update":{"messageId":"answer","content":{"type":"text","text":"Ready."}}}}}}"#
        #expect(wire.receive(canonical, session: "s") == [.init(id: "answer:0", text: "Ready.", done: false)])
        let tool = #"{"method":"_acpmux/event","params":{"sessionId":"s","seq":5,"kind":"tool_call_update","msg":{"text":"secret tool result"}}}"#
        #expect(wire.receive(tool, session: "s").isEmpty)
        let end = #"{"method":"_acpmux/event","params":{"sessionId":"s","seq":6,"kind":"turn_end"}}"#
        #expect(wire.receive(end, session: "s") == [.init(id: "answer:0", text: "", done: true)])
        #expect(wire.receive(end, session: "s").isEmpty)
    }
    private func fullChunk(session: String = "s", ref: Int = 7, sequence: Int = 1, text: String = "Hello") -> String {
        #"{"method":"_acpmux/event","params":{"sessionId":"\#(session)","seq":\#(sequence),"chunkRef":\#(ref),"kind":"agent_message_chunk","msg":{"params":{"update":{"messageId":"answer","content":{"type":"text","text":"\#(text)"}}}}}}"#
    }
    private func compactChunk(ref: Int = 7, sequence: Int = 2, text: String = " world") -> String {
        #"{"method":"_acpmux/chunk","params":{"ref":\#(ref),"seq":\#(sequence),"dt":1,"text":"\#(text)"}}"#
    }
    @Test func compactChunksSpeakTheWholeAnswerAndFlushAcrossToolAndTurnBoundaries() {
        var wire = AgentPaneVoiceWire()
        var answer = wire.receive(fullChunk(), session: "s")
        answer += wire.receive(compactChunk(), session: "s")
        answer += wire.receive(compactChunk(sequence: 3, text: "!"), session: "s")
        #expect(answer.map(\.text).joined() == "Hello world!")
        #expect(answer.allSatisfy { $0.id == "answer:0" && !$0.done })
        let tool = #"{"method":"_acpmux/event","params":{"sessionId":"s","seq":4,"kind":"tool_call"}}"#
        #expect(wire.receive(tool, session: "s") == [.init(id: "answer:0", text: "", done: true)])
        // The server retains its template across non-chunk events; so must the adapter.
        #expect(wire.receive(compactChunk(sequence: 5, text: "Done."), session: "s") == [.init(id: "answer:1", text: "Done.", done: false)])
        let end = #"{"method":"_acpmux/event","params":{"sessionId":"s","seq":6,"kind":"turn_end"}}"#
        #expect(wire.receive(end, session: "s") == [.init(id: "answer:1", text: "", done: true)])
        #expect(wire.receive(compactChunk(sequence: 5), session: "s").isEmpty)
    }
    @Test func compactRefsCannotCrossChatsReplaceNewerTemplatesOrAdvanceTheCursorWhenUnknown() {
        var wire = AgentPaneVoiceWire()
        #expect(wire.receive(compactChunk(sequence: 100), session: "s").isEmpty)
        #expect(!wire.receive(fullChunk(), session: "s").isEmpty)
        #expect(wire.receive(fullChunk(session: "other", ref: 8, sequence: 100), session: "s").isEmpty)
        #expect(wire.receive(compactChunk(ref: 8, sequence: 101), session: "s").isEmpty)
        #expect(wire.receive(compactChunk(), session: "s") == [.init(id: "answer:0", text: " world", done: false)])
        #expect(wire.receive(compactChunk(), session: "s").isEmpty)
        #expect(!wire.receive(fullChunk(ref: 9, sequence: 3), session: "s").isEmpty)
        #expect(wire.receive(fullChunk(sequence: 1), session: "s").isEmpty)
        #expect(wire.receive(compactChunk(sequence: 200), session: "s").isEmpty)
        #expect(!wire.receive(compactChunk(ref: 9, sequence: 4), session: "s").isEmpty)
        #expect(wire.receive(compactChunk(ref: 9, sequence: 5), session: "other").isEmpty)
        #expect(!wire.receive(fullChunk(session: "other", ref: 10), session: "other").isEmpty)
        // A new connection lease has no templates, even if the server reuses the numeric ref.
        wire = AgentPaneVoiceWire()
        #expect(wire.receive(compactChunk(ref: 10), session: "other").isEmpty)
    }
    @Test func anEmptyFullChunkStillTeachesItsTemplateButMalformedDeltasDoNotAdvanceIt() {
        var wire = AgentPaneVoiceWire()
        #expect(wire.receive(fullChunk(text: ""), session: "s").isEmpty)
        #expect(wire.receive(#"{"method":"_acpmux/chunk","params":{"ref":7,"seq":99,"dt":-1,"text":"wrong"}}"#, session: "s").isEmpty)
        #expect(wire.receive(compactChunk(), session: "s") == [.init(id: "answer:0", text: " world", done: false)])
    }
    @Test func promptUsesTheExistingChatAndOneStableDeduplicationId() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(AgentPaneVoiceWire.prompt(session: "remote-chat", id: "u1", text: "a\n\"b").utf8))
        #expect(value["method"]?.stringValue == "session/prompt")
        #expect(value["params"]?["sessionId"]?.stringValue == "remote-chat")
        #expect(value["params"]?["_meta"]?["acpmux"]?["promptId"]?.stringValue == "voice-u1")
        #expect(value["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue == "a\n\"b")
    }
    @Test @MainActor func allVoiceCommandsReachBothPageHosts() {
        for (method, command) in [("voice.toggle", AgentPaneVoiceCommand.toggle), ("voice.cancel", .cancel), ("voice.skip", .skip), ("voice.restart", .restart)] {
            #expect(AgentPaneRequest(body: ["method": method]) == .voice(command))
            #expect(AgentPageOps.methods[method] == method)
        }
    }
}

@Suite(.serialized) @MainActor struct AgentPaneVoiceCancellationTests {
    final class Lease { var live = true }
    @Test func cancelledVoicePromptCannotSendAfterAsyncTransportAnalysis() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        let lease = Lease()
        pane.transport.afterAnalyze = { lease.live = false }
        let result = await withCheckedContinuation { continuation in
            pane.transport.submit(connection: pane.id,
                frames: [AgentPaneVoiceWire.prompt(session: "s-new", id: "cancelled", text: "must not send")],
                valid: { lease.live }) { continuation.resume(returning: $0) }
        }
        #expect(result == .staleConnection)
        #expect(!pane.server.peers.flatMap(\.frames).contains { $0.contains("voice-cancelled") })
    }
    @Test func cancellationBeforeQueueDrainRefusesWithoutAnalyzing() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        var analyzed = false
        pane.transport.afterAnalyze = { analyzed = true }
        let result = await withCheckedContinuation { continuation in
            pane.transport.submit(connection: pane.id,
                frames: [AgentPaneVoiceWire.prompt(session: "s-new", id: "cancelled", text: "must not send")],
                valid: { false }) { continuation.resume(returning: $0) }
        }
        #expect(result == .staleConnection)
        #expect(!pane.server.peers.flatMap(\.frames).contains { $0.contains("voice-cancelled") })
        #expect(!analyzed)
    }
}

@Suite @MainActor struct AgentPaneVoicePlaybackTests {
    @Test func aCancelledUtteranceCannotAdvanceTheVoiceQueue() {
        let voice = AgentPaneReadAloudTests.FakeVoice()
        let reader = AgentPaneReadAloud(voice: voice)
        let owner = AgentPaneReadAloudTests.Owner()
        var completions = 0
        reader.speak("old", id: "one", language: nil, owner: owner) { completions += 1 }
        reader.stop(owner: owner)
        voice.finish[0]()
        #expect(completions == 0)
        reader.speak("new", id: "two", language: nil, owner: owner) { completions += 1 }
        voice.finish[1]()
        #expect(completions == 1)
    }
}

@Suite @MainActor struct AgentPaneVoiceRecoveryTests {
    @Test func failedWordsUseComposerRecoveryWithoutAnAutoSendTerminalEvent() throws {
        let updates = AgentPaneVoiceRelay.recoveryUpdates(text: "Keep my words", session: "chat-one")
        #expect(updates.count == 2)
        #expect(updates.first?.phase == .starting)
        #expect(updates.last?.text == "Keep my words")
        #expect(updates.allSatisfy { $0.chat == "chat-one" && !$0.cancelled && $0.phase != .idle })
        let events = updates.compactMap(AgentPageEvent.dictation)
        #expect(events.count == 2)
        #expect(events.last?.value["state"]?.stringValue == "failed")
        #expect(events.last?.value["text"]?.stringValue == "Keep my words")
        #expect(events.last?.value["session"]?.stringValue == "chat-one")
        #expect(updates.compactMap(AgentPaneDictation.script).count == 2)
        #expect(AgentPaneVoiceRelay.recoveryUpdates(text: " \n", session: "chat-one").isEmpty)
    }
}
