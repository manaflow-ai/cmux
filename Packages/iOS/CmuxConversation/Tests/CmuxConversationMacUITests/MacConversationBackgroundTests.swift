import AppKit
import Foundation
import Testing
@testable import CmuxConversationCore
@testable import CmuxConversationMacUI

/// Conversation backgrounds on macOS: system lines, the derived transcript
/// appearance, the incoming bubble material and the picker's actions.
@MainActor
@Suite(.serialized) struct MacConversationBackgroundTests {
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("condition not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aBackgroundSystemLineIsACenteredNoticeNamingTheActor() async throws {
        let store = ConversationStore(backend: MemoryBackend(id: "group", kind: .group))
        store.start()
        try await until { store.hasLoadedNewest }
        var line = ConversationMessage(id: "m7", seq: 7, clientMessageID: nil, senderID: "lc", sentAt: Date(), text: "")
        line.systemEvent = ConversationSystemEvent(kind: .changedBackground)
        store.apply(.message(line, eventSeq: 1))
        var mine = ConversationMessage(id: "m8", seq: 8, clientMessageID: nil, senderID: "me", sentAt: Date(), text: "")
        mine.systemEvent = ConversationSystemEvent(kind: .removedBackground)
        store.apply(.message(mine, eventSeq: 2))
        let rows = MacConversationRowBuilder.rows(store: store)
        let notices = rows.compactMap { row -> String? in
            if case let .systemEvent(id, text) = row, id.hasPrefix("system:") { return text.text }
            return nil
        }
        // Status rows name the actor in full (emphasized), as group status rows do.
        #expect(notices.count == 2 && notices[0].hasPrefix("Lawrence") && notices[0].hasSuffix(" changed the background."))
        #expect(notices.last == "You removed the background.")
        #expect(!rows.contains { if case let .message(model) = $0 { return model.message.systemEvent != nil } else { return false } })
        store.stop()
    }

    @Test func darkBackgroundsDarkenTheTranscriptAndLightOnesLightenIt() {
        let dusk = ConversationBackgroundDraft(look: ConversationBackgroundLook.named("sky.dusk")!).optimisticBackground(id: "a", setBy: nil)
        let ice = ConversationBackgroundDraft(look: ConversationBackgroundLook.named("color.ice")!).optimisticBackground(id: "b", setBy: nil)
        #expect(MacBackdropAppearance.name(for: dusk) == .darkAqua)
        #expect(MacBackdropAppearance.name(for: ice) == .aqua)
        #expect(MacBackdropAppearance.name(for: nil) == nil)
        #expect(MacBubbleBackdrop.style(for: dusk, reduceTransparency: false) == .material)
        #expect(MacBubbleBackdrop.style(for: dusk, reduceTransparency: true) == .opaque)
        #expect(MacBubbleBackdrop.style(for: nil, reduceTransparency: false) == .none)
    }

    @Test func pickerActionsFollowTheSelection() {
        let current = ConversationBackgroundDraft(look: ConversationBackgroundLook.named("sky.dusk")!).optimisticBackground(id: "bg", setBy: "lc")
        var model = MacBackgroundPickerModel(current: current)
        #expect(model.kind == .sky && model.lookID == "sky.dusk")
        #expect(model.action == .none)
        model.select(kind: .aurora)
        #expect(model.lookID == ConversationBackgroundLook.looks(for: .aurora).first?.id)
        guard case let .set(draft) = model.action else {
            Issue.record("expected set")
            return
        }
        #expect(draft.kind == .aurora && draft.look == model.lookID && !draft.colors.isEmpty)
        model.select(customHex: "#112233")
        #expect(model.action == .set(.color("#112233")))
        model.select(kind: .photo)
        #expect(model.action == .none)
        model.photo = .init(data: Data([1]), mimeType: "image/png", width: 3, height: 4, luminance: 0.2)
        #expect(model.action == .setPhoto(model.photo!))
        model.select(kind: nil)
        #expect(model.action == .clear)
        #expect(MacBackgroundPickerModel(current: nil).action == .none)
    }

    @Test func aBackgroundRestylesTheTranscriptAndOffersEditBackground() async throws {
        let backend = MacBackgroundBackend()
        let store = ConversationStore(backend: backend)
        let controller = MacConversationViewController(store: store)
        _ = controller.view
        try await until { store.info != nil }
        #expect(controller.scrollView.drawsBackground)
        #expect(controller.view.appearance == nil)
        #expect(controller.backgroundContextMenu()?.items.map(\.title) == ["Edit Background"])

        store.setBackground(ConversationBackgroundDraft(look: ConversationBackgroundLook.named("water.deepSea")!))
        #expect(!controller.scrollView.drawsBackground)
        #expect(controller.view.appearance?.name == .darkAqua)
        #expect(controller.backdropView.backdrop.background?.kind == .water)
        try await until { backend.received.count == 1 }

        store.setBackground(nil)
        #expect(controller.scrollView.drawsBackground)
        #expect(controller.view.appearance == nil)
        #expect(controller.backdropView.isHidden)
        store.stop()
    }

    @Test func backendsWithoutBackgroundsOfferNoPicker() async throws {
        let store = ConversationStore(backend: MemoryBackend(id: "direct", kind: .direct))
        let controller = MacConversationViewController(store: store)
        _ = controller.view
        try await until { store.info != nil }
        #expect(controller.backgroundContextMenu() == nil)
        #expect(!controller.canPerform(#selector(MacConversationViewController.editBackground(_:))))
        store.stop()
    }
}

/// Connects with a direct conversation and accepts backgrounds.
final class MacBackgroundBackend: ConversationBackgroundBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "direct", title: "Lawrence Chen", kind: .direct, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#30B0C7", isMe: false),
    ])
    private let lock = NSLock()
    private var _received: [ConversationBackgroundDraft?] = []
    var received: [ConversationBackgroundDraft?] { lock.withLock { _received } }

    func setConversationBackground(_ draft: ConversationBackgroundDraft?) async throws -> ConversationInfo {
        var result = info
        result.background = lock.withLock {
            _received.append(draft)
            return draft?.optimisticBackground(id: "srv_\(_received.count)", setBy: "me")
        }
        return result
    }

    func events() -> AsyncStream<ConversationBackendEvent> {
        let info = info
        return AsyncStream { $0.yield(.connected(info: info, meID: "me", lagged: false)) }
    }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage { ConversationHistoryPage(messages: [], hasMore: false) }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func unsend(messageID: String) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw ConversationBackendError(code: -1, message: "unsupported") }
    func close() {}
}
