import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the composer's pending-attachment store logic
/// (add/remove/clear, per-terminal keying, send-enabled gating). The actual
/// image RPC and the post-ack text reconciliation are covered elsewhere; these
/// drive the staging state directly, which is what the composer's chip row and
/// Send gating read.
@MainActor
@Suite struct ComposerPendingAttachmentTests {
    private static let terminalA = MobileTerminalPreview(id: "term-a", name: "a")
    private static let terminalB = MobileTerminalPreview(id: "term-b", name: "b")

    /// A composite selected on `term-a`. Selection is set by `init` (no `didSet`
    /// draft swap fires), so the store contents stay exactly what each test seeds.
    private static func makeComposite() -> MobileShellComposite {
        MobileShellComposite(
            workspaces: [
                MobileWorkspacePreview(id: "ws-1", name: "ws", terminals: [terminalA, terminalB]),
            ]
        )
    }

    private static func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func addAppendsInPickOrder() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("one"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("two"), format: "jpg", forTerminalID: "term-a")

        let staged = composite.pendingAttachments(forTerminalID: "term-a")
        #expect(staged.count == 2)
        #expect(staged[0].data == Self.bytes("one"))
        #expect(staged[0].format == "png")
        #expect(staged[1].data == Self.bytes("two"))
        #expect(staged[1].format == "jpg")
    }

    @Test func addIgnoresEmptyData() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Data(), format: "png", forTerminalID: "term-a")
        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
    }

    @Test func removeDropsOnlyTheTargetedAttachment() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("one"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("two"), format: "png", forTerminalID: "term-a")
        let toRemove = composite.pendingAttachments(forTerminalID: "term-a")[0].id

        composite.removePendingAttachment(id: toRemove, forTerminalID: "term-a")

        let staged = composite.pendingAttachments(forTerminalID: "term-a")
        #expect(staged.count == 1)
        #expect(staged[0].data == Self.bytes("two"))
    }

    @Test func clearEmptiesOnlyTheGivenTerminal() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("a1"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("b1"), format: "png", forTerminalID: "term-b")

        composite.clearPendingAttachments(forTerminalID: "term-a")

        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").count == 1)
    }

    @Test func attachmentsAreKeyedPerTerminal() {
        let composite = Self.makeComposite()
        composite.addPendingAttachment(Self.bytes("a1"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("b1"), format: "png", forTerminalID: "term-b")
        composite.addPendingAttachment(Self.bytes("b2"), format: "png", forTerminalID: "term-b")

        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").count == 2)
    }

    @Test func defaultsToSelectedTerminalWhenIDOmitted() {
        let composite = Self.makeComposite()
        // Selected terminal is term-a (set at init).
        composite.addPendingAttachment(Self.bytes("sel"), format: "png")
        #expect(composite.pendingAttachments().count == 1)
        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").isEmpty)
    }

    @Test func canSendWhenTextEmptyButAttachmentPresent() {
        let composite = Self.makeComposite()
        composite.terminalInputText = ""
        #expect(composite.composerCanSend(forTerminalID: "term-a") == false)

        composite.addPendingAttachment(Self.bytes("img"), format: "png", forTerminalID: "term-a")
        #expect(composite.composerCanSend(forTerminalID: "term-a") == true)
    }

    @Test func canSendWhenTextPresentButNoAttachment() {
        let composite = Self.makeComposite()
        composite.terminalInputText = "hello"
        #expect(composite.composerCanSend(forTerminalID: "term-a") == true)
    }

    @Test func cannotSendWhenTextWhitespaceAndNoAttachment() {
        let composite = Self.makeComposite()
        composite.terminalInputText = "   \n  "
        #expect(composite.composerCanSend(forTerminalID: "term-a") == false)
    }

    @Test func signOutClearsPendingAttachments() {
        let composite = Self.makeComposite()
        // A previous account stages photo bytes on two terminals.
        composite.addPendingAttachment(Self.bytes("a-img"), format: "png", forTerminalID: "term-a")
        composite.addPendingAttachment(Self.bytes("b-img"), format: "png", forTerminalID: "term-b")

        // Sign-out is the account-bound reset that wipes the previous user's
        // unsent content (text drafts, etc.); the staged photo bytes must go too
        // so a reused terminal id under the next account never resurfaces them.
        composite.signOut()

        #expect(composite.pendingAttachments(forTerminalID: "term-a").isEmpty)
        #expect(composite.pendingAttachments(forTerminalID: "term-b").isEmpty)
    }

    @Test func submitKeepsAttachmentsWhenSendFails() async {
        let composite = Self.makeComposite()
        // No remoteClient is wired, so the image send fails (returns false). A
        // failed send must KEEP the staged attachments so the user can retry,
        // matching the text-keep-on-failure semantics of submitComposerInput().
        composite.addPendingAttachment(Self.bytes("img"), format: "png", forTerminalID: "term-a")
        composite.terminalInputText = ""

        await composite.submitComposer()

        #expect(composite.pendingAttachments(forTerminalID: "term-a").count == 1)
    }
}
