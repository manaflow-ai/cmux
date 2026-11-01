import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The user bubble's Edit and Resend: it puts the message in the composer to edit and
/// sends nothing until the person sends it, and a draft in the composer is never replaced.
@MainActor
@Suite struct EditAndResendTests {
    private func lastTurn() -> (PromptResendTests.Recorder, AgentChatStore, AgentTurn) {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.userMessage(text: "fix the build", promptId: "p1", turnId: "t1", attachments: [], at: Date()))
        return (source, store, AgentTurn(id: "t1", prompt: "fix the build", promptAt: Date()))
    }

    @Test func emptyComposerGetsTheMessageAndNothingIsSent() {
        let (source, store, turn) = lastTurn()
        let sentBefore = source.sent.count
        #expect(store.editAndResend(turn, draft: "") == "fix the build")
        #expect(source.sent.count == sentBefore)
    }

    @Test func whitespaceDraftCountsAsEmpty() {
        let (source, store, turn) = lastTurn()
        let sentBefore = source.sent.count
        #expect(store.editAndResend(turn, draft: " \n\t ") == "fix the build")
        #expect(source.sent.count == sentBefore)
    }

    @Test func occupiedDraftIsNeverReplacedOrSent() {
        let (source, store, turn) = lastTurn()
        let sentBefore = source.sent.count
        // Draft B stays: nothing comes back for the composer, and nothing goes to the agent.
        #expect(store.editAndResend(turn, draft: "draft B") == nil)
        #expect(source.sent.count == sentBefore)
    }

    /// The edited message, once the person sends it, goes as a new prompt.
    @Test func sendingTheEditGoesAsANewPrompt() throws {
        let (source, store, turn) = lastTurn()
        let seeded = try #require(store.editAndResend(turn, draft: ""))
        store.send(prompt: seeded + " and the tests")
        let sent = try #require(PromptResendTests.prompt(source.sent.last))
        #expect(sent.text == "fix the build and the tests")
        #expect(sent.id != "p1")
        #expect(!sent.resend)
    }

    #if os(iOS)
    // AgentChatSurface is iOS only; the store tests above also run in macOS `swift test`.

    /// The bubble's path: the composer gets the message, focused, and nothing is sent.
    @Test func bubbleEditFillsAndFocusesTheComposer() {
        let (source, store, turn) = lastTurn()
        let sentBefore = source.sent.count
        let surface = AgentChatSurface()
        #expect(surface.editAndResend(turn, store: store))
        #expect(surface.text == "fix the build")
        #expect(surface.composerFocused)
        #expect(source.sent.count == sentBefore)
    }

    /// With a draft, the bubble's path changes nothing (it asks first).
    @Test func bubbleEditKeepsADraft() {
        let (source, store, turn) = lastTurn()
        let sentBefore = source.sent.count
        let surface = AgentChatSurface()
        surface.text = "draft B"
        #expect(!surface.editAndResend(turn, store: store))
        #expect(surface.text == "draft B")
        #expect(!surface.composerFocused)
        #expect(source.sent.count == sentBefore)
    }

    /// With permission choices up, the composer replaces them as a follow-up, never as
    /// "Reply instead" (which would deny the request), so the edit is never hidden.
    @Test func editDuringAPermissionShowsTheComposer() {
        let surface = AgentChatSurface()
        #expect(!surface.permissionBarHidden)
        surface.loadForEditing("fix the build", permissionPending: true)
        #expect(surface.permissionBarHidden)
        #expect(!surface.replyInsteadOfPermission)
        #expect(surface.text == "fix the build")
        #expect(surface.composerFocused)
    }

    /// An edit loaded while "Reply instead" is open is a follow-up, not a denial.
    @Test func editEndsReplyInstead() {
        let surface = AgentChatSurface()
        surface.replyInsteadOfPermission = true
        surface.loadForEditing("fix the build", permissionPending: true)
        #expect(!surface.replyInsteadOfPermission)
        #expect(surface.permissionBarHidden)
    }
    #endif
}
