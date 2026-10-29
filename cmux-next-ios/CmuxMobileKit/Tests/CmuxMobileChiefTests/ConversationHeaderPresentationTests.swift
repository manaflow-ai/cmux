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

    private func makeController(header: ConversationHeaderPresentation = .init()) -> ConversationViewController {
        let store = ConversationStore(backend: HeaderBackend())
        let controller = ConversationViewController(store: store, options: .init(header: header))
        controller.loadViewIfNeeded()
        return controller
    }
}

private final class HeaderBackend: ConversationBackend, Sendable {
    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { $0.finish() } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        .init(messages: [], hasMore: false)
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
