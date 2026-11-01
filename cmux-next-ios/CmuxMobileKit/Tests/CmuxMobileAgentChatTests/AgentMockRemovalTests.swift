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

    @Test func offlinePromptReturnsDraftWithConciseReason() async throws {
        let source = DisconnectedAgentSource(summary: summary)
        let store = AgentChatStore(source: source)
        let attachment = AgentAttachment(kind: .file, name: "notes.txt", data: Data("notes".utf8))
        store.send(prompt: "run the tests", attachments: [attachment])

        for _ in 0..<100 where store.returnedDraft == nil { await Task.yield() }
        let draft = try #require(store.returnedDraft)
        #expect(draft.text == "run the tests")
        #expect(draft.attachments == [attachment])
        #expect(draft.promptID != nil)
        #expect(store.clientError == "Mac offline. Not sent.")
        #expect(store.canRetryPrompt)

        store.returnedDraft = nil // The composer has restored the text and attachments.
        store.send(prompt: draft.text, attachments: draft.attachments)
        for _ in 0..<100 where store.returnedDraft == nil { await Task.yield() }
        #expect(store.returnedDraft?.text == draft.text)
        #expect(store.returnedDraft?.attachments == draft.attachments)
        #expect(store.returnedDraft?.promptID == draft.promptID)
    }
}
