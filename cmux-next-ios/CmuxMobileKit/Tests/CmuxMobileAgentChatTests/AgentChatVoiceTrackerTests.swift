import CmuxMobileRealtime
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// What voice mode says of a GUI agent chat: new, finished messages and
/// what needs the user; never tool calls, diffs, thoughts or old history.
@Suite struct AgentChatVoiceTrackerTests {
    static func turn(_ id: String, _ items: [TurnItem], status: AgentTurn.Status = .running) -> AgentTurn {
        var turn = AgentTurn(id: id, prompt: "p", promptAt: Date(timeIntervalSince1970: 1))
        turn.items = items
        turn.status = status
        return turn
    }

    static let edit = ACPToolCall(id: "c1", title: "Edit Store.swift", kind: .edit, status: .completed,
                                  content: [.diff(path: "Store.swift", oldText: "a", newText: "b")])

    @Test func historyBeforeVoiceModeIsNotRead() {
        var tracker = AgentChatVoiceTracker(speech: AgentVoiceSpeech())
        tracker.baseline([Self.turn("t0", [.message(id: "old", markdown: "Old answer.")], status: .completed)])
        #expect(tracker.newSpeech(in: [Self.turn("t0", [.message(id: "old", markdown: "Old answer.")], status: .completed)]).isEmpty)
    }

    @Test func aMessageIsReadOnceItIsCompleteNotWhileItStreams() {
        var tracker = AgentChatVoiceTracker(speech: AgentVoiceSpeech())
        tracker.baseline([])
        // Streaming: the last item of a running turn may still grow.
        #expect(tracker.newSpeech(in: [Self.turn("t1", [.message(id: "m1", markdown: "Looking at the")])]).isEmpty)
        // A tool call follows it: the message is complete.
        let turns = [Self.turn("t1", [.message(id: "m1", markdown: "Looking at the store."), .tool(Self.edit)])]
        #expect(tracker.newSpeech(in: turns) == ["Looking at the store."])
        // Said once.
        #expect(tracker.newSpeech(in: turns).isEmpty)
    }

    @Test func toolCallsDiffsAndThoughtsAreNeverRead() {
        var tracker = AgentChatVoiceTracker(speech: AgentVoiceSpeech())
        tracker.baseline([])
        let turns = [Self.turn("t1", [
            .thought(id: "th", text: "I should edit the store"),
            .tool(Self.edit),
            .plan(id: "p", entries: [ACPPlanEntry(content: "Edit the store")]),
            .message(id: "m", markdown: "Fixed it.\n\n```diff\n-a\n+b\n```"),
        ], status: .completed)]
        #expect(tracker.newSpeech(in: turns) == ["Fixed it."])
    }

    @Test func permissionRequestsAndQuestionsAreRead() {
        var tracker = AgentChatVoiceTracker(speech: AgentVoiceSpeech())
        tracker.baseline([])
        let request = ACPPermissionRequest(id: "r1", toolCall: ACPToolCall(id: "c2", title: "Run `make test`", kind: .execute),
                                           options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        let turns = [Self.turn("t1", [.permission(PermissionRecord(request: request))])]
        #expect(tracker.newSpeech(in: turns) == ["Needs your permission: Run make test."])
    }

    @Test func aFailedTurnSaysSo() {
        var tracker = AgentChatVoiceTracker(speech: AgentVoiceSpeech())
        tracker.baseline([])
        var failed = Self.turn("t1", [], status: .failed)
        failed.errorText = "Rate limited."
        #expect(tracker.newSpeech(in: [failed]) == ["The turn failed: Rate limited."])
        #expect(tracker.newSpeech(in: [failed]).isEmpty)
    }

    @Test func editsWithoutWordsAreCountedNotRead() {
        var tracker = AgentChatVoiceTracker(speech: AgentVoiceSpeech())
        tracker.baseline([])
        #expect(tracker.newSpeech(in: [Self.turn("t1", [.tool(Self.edit)], status: .completed)]) == ["Edited one file."])
    }

    @Test func aMessageStreamingWhenVoiceModeStartsIsReadWhenComplete() {
        var tracker = AgentChatVoiceTracker(speech: AgentVoiceSpeech())
        tracker.baseline([Self.turn("t1", [.tool(Self.edit), .message(id: "m0", markdown: "Running the")])])
        let done = Self.turn("t1", [.tool(Self.edit), .message(id: "m0", markdown: "Running the tests."),
                                    .message(id: "m1", markdown: "All green.")], status: .completed)
        // The edit was on screen already: not counted again at the turn's end either.
        #expect(tracker.newSpeech(in: [done]) == ["Running the tests.", "All green."])
    }
}
