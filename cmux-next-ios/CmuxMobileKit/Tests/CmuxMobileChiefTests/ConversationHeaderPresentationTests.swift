#if canImport(UIKit)
import Testing
import UIKit
@testable import CmuxConversationCore
@testable import CmuxConversationUI

@MainActor
@Suite(.serialized)
struct ConversationHeaderPresentationTests {
    @Test func systemEdgeReservesTheFullHeaderAndCustomSpacing() {
        let controller = makeController(header: .init(scrollEdge: .system, transcriptTopSpacing: 24))
        defer { controller.store.stop() }
        controller.additionalSafeAreaInsets.top = 62
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        let headerBottom = controller.header.frame.maxY
        #expect(headerBottom > 62)
        #expect(controller.collectionView.contentInset.top == headerBottom + 24)
        #expect(controller.collectionView.safeAreaInsets.top >= headerBottom + 24)
        if #available(iOS 26.0, *) {
            #expect(!controller.collectionView.topEdgeEffect.isHidden)
            #expect(controller.topEdgeFade.isHidden)
        }
    }

    @Test func normalActionActivatesWithoutTouchDownAndCancelDoesNotInvite() {
        let controller = makeController(header: .init(actionAccessibilityLabel: "Invite"))
        defer { controller.store.stop() }
        var activations = 0
        controller.onHeaderAction = { [weak controller] anchor in
            #expect(anchor === controller?.header.trailingButton)
            activations += 1
        }
        #expect(controller.header.trailingButton.accessibilityLabel == "Invite")
        controller.header.trailingButton.sendActions(for: .touchUpInside)
        #expect(activations == 1)
        controller.setSelecting(true)
        controller.header.trailingButton.sendActions(for: .touchUpInside)
        #expect(!controller.isSelecting)
        #expect(activations == 1)
        controller.header.trailingButton.sendActions(for: .touchUpInside)
        #expect(activations == 2)
    }

    /// The user, 2026-11-10: the top and bottom bars' scroll edge must be the
    /// native one, not a manufactured blur. `.system` draws nothing of its
    /// own: UIKit's soft edge effect, its safe area reaching the header's
    /// bottom, covers the header, and the composer's bottom edge stays native.
    @Test func systemHeaderUsesOnlyTheNativeScrollEdgeEffect() {
        let controller = makeController(header: .init(scrollEdge: .system))
        let messages = makeController()
        defer { controller.store.stop(); messages.store.stop() }
        for host in [controller, messages] {
            host.additionalSafeAreaInsets.top = 62
            host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            host.view.layoutIfNeeded()
        }
        // Opting in never changes the resting transcript layout.
        #expect(controller.collectionView.contentInset == messages.collectionView.contentInset)
        #expect(controller.header.frame == messages.header.frame)
        guard #available(iOS 26.0, *) else { return }
        let collection = controller.collectionView
        let headerBottom = controller.header.frame.maxY - collection.frame.minY
        for offset in [-collection.contentInset.top, 100, 400] {
            collection.contentOffset.y = offset
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            #expect(collection.layer.mask == nil)
            #expect(!collection.topEdgeEffect.isHidden)
            #expect(collection.topEdgeEffect.style == .soft)
            #expect(collection.bottomEdgeEffect.style == .soft)
            // The native pocket reaches the header's bottom.
            #expect(collection.safeAreaInsets.top >= headerBottom - 0.5)
        }
    }

    @Test func nameUsesTheHostActionAndDefaultsKeepMessagesSpacing() {
        let controller = makeController()
        defer { controller.store.stop() }
        controller.store.apply(.conversationChanged(.init(id: "demo", title: "Chief", kind: .group, participants: [])))
        var opened = false
        controller.onHeaderInfo = { opened = true }
        controller.header.nameButton.sendActions(for: .touchUpInside)
        #expect(opened)
        #expect(controller.detailsController == nil)
        #expect(controller.options.header.scrollEdge == .messages)
        #expect(controller.options.header.transcriptTopSpacing == nil)
        #expect(controller.collectionView.edgeTopInset == 0)
        #expect(controller.collectionView.layer.mask == nil)
    }

    @Test func hostActionRunsBeforeConversationInfoExists() {
        let controller = makeController()
        defer { controller.store.stop() }
        var opened = false
        controller.onHeaderInfo = { opened = true }
        #expect(controller.store.info == nil)
        controller.header.nameButton.sendActions(for: .touchUpInside)
        #expect(opened)
        #expect(controller.detailsController == nil)
    }

    @Test(.timeLimit(.minutes(1))) func hostMaterialCoversReplyCopiesWithoutClippingOrBlurringComposer() async throws {
        for edge in [ConversationHeaderPresentation.ScrollEdge.messages, .system] {
            let message = ConversationMessage(id: "reply-root", seq: 1, clientMessageID: nil, senderID: "agent", sentAt: Date(), text: "A long thread")
            let controller = makeController(header: .init(scrollEdge: edge), history: [message])
            defer { controller.store.stop() }
            // Seed through the real newest-page path. Live messages arriving
            // before that page are buffered and cannot open a reply thread.
            let (loaded, continuation) = AsyncStream<Void>.makeStream()
            controller.store.addObserver { change in
                if change == .reset { continuation.yield(()); continuation.finish() }
            }
            controller.store.apply(.connected(
                info: .init(id: "demo", title: "Chief", kind: .group, participants: []),
                meID: "me", lagged: false
            ))
            var pages = loaded.makeAsyncIterator()
            _ = await pages.next()
            try #require(controller.store.hasLoadedNewest)
            try #require(controller.store.message(id: message.id) != nil)
            controller.additionalSafeAreaInsets.top = 62
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            controller.view.layoutIfNeeded()
            controller.enterReplyMode(for: message)
            guard let overlay = controller.replyOverlay else {
                Issue.record("Reply thread did not open")
                continue
            }
            overlay.contentHeight = 2_000
            controller.composerContainer.frame.origin.y = 450
            controller.layoutReplyOverlay()
            #expect(!overlay.content.clipsToBounds)
            if #available(iOS 26.0, *), edge == .system {
                let siblings = controller.view.subviews
                let replyIndex = siblings.firstIndex(of: overlay) ?? -1
                let composerIndex = siblings.firstIndex(of: controller.composerContainer) ?? -1
                let headerIndex = siblings.firstIndex(of: controller.header) ?? -1
                #expect(replyIndex >= 0 && replyIndex < composerIndex && composerIndex < headerIndex)
            }
            #expect(overlay.content.frame.minY == controller.header.frame.maxY)
            #expect(overlay.content.contentOffset.y > 0)
            overlay.removeFromSuperview()
        }
    }

    private func makeController(header: ConversationHeaderPresentation = .init(), history: [ConversationMessage] = []) -> ConversationViewController {
        let store = ConversationStore(backend: HeaderBackend(messages: history))
        let controller = ConversationViewController(store: store, options: .init(header: header))
        controller.loadViewIfNeeded()
        return controller
    }
}

private final class HeaderBackend: ConversationBackend, Sendable {
    let messages: [ConversationMessage]
    init(messages: [ConversationMessage]) { self.messages = messages }
    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { $0.finish() } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        .init(messages: messages, hasMore: false)
    }
    private var unsupported: ConversationBackendError { .init(code: -1, message: "No writes in header tests") }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { throw unsupported }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw unsupported }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { throw unsupported }
    func unsend(messageID: String) async throws -> ConversationMessage { throw unsupported }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw unsupported }
    func close() {}
}
#endif
