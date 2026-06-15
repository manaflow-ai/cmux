import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// End-to-end tests over the real RPC wire (a scripted recording host) that lock
/// in the composer's send routing: attachments and text target the terminal
/// captured at submit time, not whatever is selected when an awaited image send
/// returns, and a failed image send keeps the remaining attachments AND the text
/// staged for a retry.
@MainActor
@Suite struct ComposerSubmitRoutingTests {
    private static func bytes(_ s: String) -> Data { Data(s.utf8) }

    /// Images and text both go to the selected terminal when nothing switches.
    @Test func sendsAttachmentsAndTextToSelectedTerminal() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(Self.bytes("one"), format: "png", forTerminalID: termA)
        store.addPendingAttachment(Self.bytes("two"), format: "jpg", forTerminalID: termA)
        store.terminalInputText = "hello"

        await store.submitComposer()

        let images = await router.recordedPasteImages()
        let pastes = await router.recordedPastes()
        #expect(images.map(\.surfaceID) == [termA, termA])
        #expect(images.map(\.format) == ["png", "jpg"])
        #expect(pastes.map(\.surfaceID) == [termA])
        #expect(pastes.first?.text == "hello")
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
    }

    /// A terminal switch WHILE the first image send is in flight must not reroute
    /// the later image or the text: both still target the captured terminal.
    @Test func midSendSwitchDoesNotRerouteLaterImageOrText() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        let termB = RoutingHostRouter.terminalB
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(Self.bytes("a-img-1"), format: "png", forTerminalID: termA)
        store.addPendingAttachment(Self.bytes("a-img-2"), format: "png", forTerminalID: termA)
        store.terminalInputText = "to-a"

        await router.setHoldFirstPasteImage(true)
        let submit = Task { await store.submitComposer() }

        // Wait until the first image send is parked, then switch the selection to
        // term-b mid-flight and release. If submit re-read selection, the second
        // image and the text would land on term-b.
        await router.awaitFirstPasteImageReached()
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termB))
        await router.releaseFirstPasteImage()
        await submit.value

        let images = await router.recordedPasteImages()
        let pastes = await router.recordedPastes()
        #expect(images.map(\.surfaceID) == [termA, termA])
        #expect(pastes.map(\.surfaceID) == [termA])
        #expect(pastes.first?.text == "to-a")
        // Nothing leaked onto term-b.
        #expect(images.allSatisfy { $0.surfaceID == termA })
        #expect(pastes.allSatisfy { $0.surfaceID == termA })
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
    }

    /// A second submit while the first is still awaiting an image RPC is rejected
    /// by the re-entrancy guard, so the same staged attachments are NOT uploaded
    /// twice (the Send button stays enabled mid-send because attachments clear
    /// only on ack).
    @Test func concurrentSubmitDoesNotDoubleUpload() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(Self.bytes("one"), format: "png", forTerminalID: termA)
        store.terminalInputText = "hello"

        // Park the first image send, fire a SECOND submit while it is in flight
        // (the double tap), then release the first. The guard must early-return
        // the second so it never re-sends the still-staged attachment or text.
        await router.setHoldFirstPasteImage(true)
        let first = Task { await store.submitComposer() }
        await router.awaitFirstPasteImageReached()
        let second = Task { await store.submitComposer() }
        await second.value
        await router.releaseFirstPasteImage()
        await first.value

        let images = await router.recordedPasteImages()
        let pastes = await router.recordedPastes()
        #expect(images.map(\.surfaceID) == [termA], "the attachment must upload exactly once")
        #expect(pastes.map(\.text) == ["hello"], "the text must paste exactly once")
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
    }

    /// A rejected image send keeps the remaining (and failed) attachments staged
    /// and does NOT submit the text, so the user can retry without losing photos.
    @Test func rejectedImageKeepsAttachmentsAndDoesNotSendText() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        await router.setRejectPasteImage(true)

        store.addPendingAttachment(Self.bytes("img-1"), format: "png", forTerminalID: termA)
        store.addPendingAttachment(Self.bytes("img-2"), format: "png", forTerminalID: termA)
        store.terminalInputText = "keep me"

        await store.submitComposer()

        // The host saw the first image but rejected it; the run stopped there.
        let images = await router.recordedPasteImages()
        let pastes = await router.recordedPastes()
        #expect(images.count == 1)
        #expect(pastes.isEmpty, "text must not send when an image send failed")
        // Both attachments are still staged (the failed one was not removed, and
        // the run never reached the second), and the text is kept in the field.
        #expect(store.pendingAttachments(forTerminalID: termA).count == 2)
        #expect(store.terminalInputText == "keep me")
    }

    /// The first image acks but the second is rejected: only the acknowledged one
    /// is cleared, the failed one (and the text) are kept.
    @Test func partialFailureClearsOnlyAcknowledgedAttachment() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(Self.bytes("ok"), format: "png", forTerminalID: termA)
        store.addPendingAttachment(Self.bytes("bad"), format: "png", forTerminalID: termA)
        store.terminalInputText = "keep me"
        let firstID = store.pendingAttachments(forTerminalID: termA)[0].id

        // First image (index 0) succeeds; the second (index 1) is rejected.
        await router.rejectPasteImage(fromIndex: 1)
        await store.submitComposer()

        let images = await router.recordedPasteImages()
        let pastes = await router.recordedPastes()
        #expect(images.count == 2, "both images were attempted; the second was rejected")
        #expect(pastes.isEmpty, "text must not send when a later image failed")
        // Only the acknowledged first image was cleared; the failed one and the
        // text are kept for a retry.
        let remaining = store.pendingAttachments(forTerminalID: termA)
        #expect(remaining.count == 1)
        #expect(remaining.first?.data == Self.bytes("bad"))
        #expect(remaining.first?.id != firstID, "the acknowledged first image was cleared")
        #expect(store.terminalInputText == "keep me")
    }
}
