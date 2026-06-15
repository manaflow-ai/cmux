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

    /// The text sent is the snapshot taken at Send time, not whatever the field
    /// holds when the (awaited) image sends return. A field edit while the first
    /// image is in flight must NOT change the text that lands on the captured
    /// terminal, and must not be discarded as already-sent on reconcile.
    @Test func textSnapshotSurvivesFieldEditMidSend() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(Self.bytes("a-img"), format: "png", forTerminalID: termA)
        store.terminalInputText = "to-a"

        await router.setHoldFirstPasteImage(true)
        let submit = Task { await store.submitComposer() }

        // Park the first image send, then edit the field mid-flight (the user
        // keeps typing after tapping Send). If the text send re-read the live
        // field, "edited after send" would paste instead of the snapshot.
        await router.awaitFirstPasteImageReached()
        store.terminalInputText = "edited after send"
        await router.releaseFirstPasteImage()
        await submit.value

        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.surfaceID) == [termA])
        #expect(pastes.first?.text == "to-a", "the snapshot taken at Send time must paste, not the mid-send edit")
        // The newer text the user typed after Send is preserved (reconcile only
        // clears when the field still equals the sent snapshot).
        #expect(store.terminalInputText == "edited after send")
    }

    /// A terminal switch mid-send swaps the draft into a different terminal's
    /// text; the captured snapshot must still be what pastes to the captured
    /// terminal, not the now-current (different) draft.
    @Test func textSnapshotSurvivesSwitchMidSend() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        let termB = RoutingHostRouter.terminalB
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(Self.bytes("a-img"), format: "png", forTerminalID: termA)
        store.terminalInputText = "to-a"

        await router.setHoldFirstPasteImage(true)
        let submit = Task { await store.submitComposer() }

        // Switch to term-b mid-flight (which swaps the draft, changing the live
        // field) and seed term-b's field with different text. The text send must
        // still paste term-a's snapshot to term-a.
        await router.awaitFirstPasteImageReached()
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termB))
        store.terminalInputText = "b-draft"
        await router.releaseFirstPasteImage()
        await submit.value

        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.surfaceID) == [termA])
        #expect(pastes.first?.text == "to-a", "term-a's snapshot must paste to term-a, not term-b's live draft")
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

    /// A chip the user deletes WHILE an earlier image's send is in flight must not
    /// upload: submitComposer iterates a snapshot taken before the awaits, but it
    /// re-checks each attachment is still staged for the captured terminal before
    /// sending it, and skips the removed one.
    @Test func midSendRemovalSkipsThatAttachment() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(Self.bytes("first"), format: "png", forTerminalID: termA)
        store.addPendingAttachment(Self.bytes("second"), format: "png", forTerminalID: termA)
        store.terminalInputText = "hello"
        let secondID = store.pendingAttachments(forTerminalID: termA)[1].id

        // Park the FIRST image send, then remove the second (not-yet-reached) chip
        // mid-flight, then release. Without the re-check the loop's pre-await
        // snapshot would still upload "second".
        await router.setHoldFirstPasteImage(true)
        let submit = Task { await store.submitComposer() }
        await router.awaitFirstPasteImageReached()
        store.removePendingAttachment(id: secondID, forTerminalID: termA)
        await router.releaseFirstPasteImage()
        await submit.value

        let images = await router.recordedPasteImages()
        let pastes = await router.recordedPastes()
        // Only the first image uploaded; the removed second was skipped.
        #expect(images.map(\.surfaceID) == [termA])
        #expect(pastes.map(\.text) == ["hello"], "text still sends after the kept image")
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
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
