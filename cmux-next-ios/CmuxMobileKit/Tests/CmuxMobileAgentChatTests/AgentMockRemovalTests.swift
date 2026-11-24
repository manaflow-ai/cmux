import CmuxMobileArtifacts
@testable import CmuxMobileAgentChat
import Foundation
import Testing

/// An agent tab with no session says it is not connected; no sample files.
@MainActor
@Suite struct DisconnectedAgentSourceTests {
    let summary = AgentSessionSummary(
        id: "t-claude", name: "Refactor", harness: "claude", agentName: "Claude",
        cwd: "~/cmux", workspaceTitle: "cmux", macName: "Aziz's Mac Studio"
    )

    @Test func saysNotConnectedInsteadOfAScriptedSession() async {
        let source = DisconnectedAgentSource(summary: summary)
        var iterator = source.events().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .clientError("Claude is on Aziz's Mac Studio. Connect to it to see this chat."))
    }

    @Test func defaultArtifactsAreUnavailableNotMock() async {
        let source = DisconnectedAgentSource(summary: summary)
        #expect(source.artifactSource is UnavailableArtifactSource)
        await #expect(throws: ArtifactUnavailable.self) {
            try await source.artifactSource.load(TerminalArtifact(reference: "README.md", kind: .markdown))
        }
    }

    /// Offline, the sent bubble stays with a quiet failed mark and the reason in its menu; its
    /// Cancel hands the text and attachments back, and sent again they keep their id.
    @Test func offlinePromptIsAFailedBubbleWithConciseReason() async throws {
        let source = DisconnectedAgentSource(summary: summary)
        let store = AgentChatStore(source: source)
        let attachment = AgentAttachment(kind: .file, name: "notes.txt", data: Data("notes".utf8))
        store.send(prompt: "run the tests", attachments: [attachment])

        for _ in 0..<100 where store.pendingPrompts.first?.look != .failed { await Task.yield() }
        let pending = try #require(store.pendingPrompts.first)
        #expect(pending.look == .failed)
        #expect(pending.reason == "Mac offline. Not sent.")
        #expect(store.turns.first?.sendLook == .failed)
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)

        store.cancelPending(pending.id)
        let draft = try #require(store.returnedDraft)
        #expect(draft.text == "run the tests")
        #expect(draft.attachments == [attachment])
        #expect(draft.promptID == pending.id)
        #expect(store.turns.isEmpty)
        #expect(store.canRetryPrompt)
    }
}
