import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationReadReceiptsSettingTests {
    @Test func sendReadReceiptsDefaultsOnAndTogglesWithoutTouchingOtherState() {
        let state = ConversationListState(muted: true)
        #expect(state.sendReadReceipts)
        let off = state.applying(.init(sendReadReceipts: false))
        #expect(!off.sendReadReceipts && off.muted)
        #expect(!ConversationListStateChange(sendReadReceipts: false).isEmpty)
        // Deleting keeps the per-conversation setting.
        #expect(!off.applying(.init(deleted: true)).sendReadReceipts)
    }

    @Test func wireDecodingReadsSendReadReceiptsAndDefaultsItOn() {
        let off = WireDecoding.conversation(["id": "g", "title": "cmux", "kind": "group", "participants": [], "sendReadReceipts": false])
        #expect(off?.listState.sendReadReceipts == false)
        let legacy = WireDecoding.conversation(["id": "g", "title": "cmux", "kind": "group", "participants": []])
        #expect(legacy?.listState.sendReadReceipts == true)
    }

    @MainActor
    @Test func togglingGoesThroughTheListStatePath() async throws {
        let backend = ListStateBackend()
        let store = ConversationStore(backend: backend)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        store.updateListState(.init(sendReadReceipts: false))
        #expect(!store.listState.sendReadReceipts)
        try await waitUntil { backend.replied }
        #expect(backend.received == [.init(sendReadReceipts: false)])
        #expect(!store.listState.sendReadReceipts)
    }
}

@MainActor
final class MemoryDraftStorage: ConversationDraftStorage {
    var drafts: [String: String] = [:]
    func draft(conversationID: String) -> String? { drafts[conversationID] }
    func setDraft(_ text: String?, conversationID: String) { drafts[conversationID] = text }
}

@MainActor
@Suite struct ConversationDraftTests {
    @Test func draftIsKeptPerConversationAndWhitespaceIsNoDraft() {
        let storage = MemoryDraftStorage()
        let backend = ListStateBackend()
        let store = ConversationStore(backend: backend, draftStorage: storage)
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))

        store.setDraft("see you\n  at   noon")
        #expect(store.draft == "see you\n  at   noon")
        #expect(store.draftSummary == "see you at noon")
        #expect(storage.drafts["g"] == "see you\n  at   noon")
        #expect(changes.last == .draft)

        store.setDraft("   \n")
        #expect(store.draft.isEmpty && store.draftSummary == nil)
        #expect(storage.drafts["g"] == nil)
    }

    @Test func savedDraftComesBackOnConnect() {
        let storage = MemoryDraftStorage()
        storage.drafts["g"] = "unsent words"
        let backend = ListStateBackend()
        let store = ConversationStore(backend: backend, draftStorage: storage)
        #expect(store.draft.isEmpty)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        #expect(store.draft == "unsent words")
    }

    @Test func draftTypedBeforeConnectingIsSavedOnConnect() {
        let storage = MemoryDraftStorage()
        let backend = ListStateBackend()
        let store = ConversationStore(backend: backend, draftStorage: storage)
        store.setDraft("early")
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        #expect(storage.drafts["g"] == "early")
        #expect(store.draft == "early")
    }
}

final class MediaBackend: ConversationBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "m", title: "media", kind: .direct, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "jo", name: "John", initials: "JA", colorHex: "#30B0C7", isMe: false),
    ])
    let total: Int
    /// Every `photoEvery`th message carries a photo; every `linkEvery`th a link card.
    let photoEvery: Int
    let linkEvery: Int
    private let lock = NSLock()
    private var _historyCalls = 0
    var historyCalls: Int { lock.withLock { _historyCalls } }

    init(total: Int, photoEvery: Int, linkEvery: Int) {
        self.total = total
        self.photoEvery = photoEvery
        self.linkEvery = linkEvery
    }

    func message(_ seq: Int) -> ConversationMessage {
        var attachments: [ConversationAttachment] = []
        if seq % photoEvery == 0 {
            attachments = [ConversationAttachment(id: "a\(seq)", kind: .image, width: 4, height: 3, url: URL(string: "http://x/\(seq).png"))]
        }
        let preview = seq % linkEvery == 0 ? ConversationLinkPreview(url: URL(string: "https://example.com/\(seq)")!, title: "Page \(seq)") : nil
        return ConversationMessage(
            id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: "jo",
            sentAt: Date(timeIntervalSince1970: TimeInterval(seq * 60)), text: preview?.url.absoluteString ?? "message \(seq)",
            attachments: attachments, linkPreview: preview
        )
    }

    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { _ in } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        lock.withLock { _historyCalls += 1 }
        let upper = (beforeSeq ?? (total + 1)) - 1
        let lower = max(1, upper - limit + 1)
        guard upper >= 1 else { return ConversationHistoryPage(messages: [], hasMore: false) }
        return ConversationHistoryPage(messages: (lower...upper).map(message), hasMore: lower > 1)
    }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func unsend(messageID: String) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw ConversationBackendError(code: -1, message: "unsupported") }
    func close() {}
}

@MainActor
@Suite struct ConversationSharedMediaTests {
    @Test func photosAndLinksListNewestFirstSkippingUnsentAndDuplicateLinks() {
        let backend = MediaBackend(total: 10, photoEvery: 2, linkEvery: 5)
        var messages = (1...10).map(backend.message)
        messages[3].unsentAt = Date() // m4: a taken-back photo
        messages[8].linkPreview = messages[4].linkPreview // m9 shares m5's link again
        let photos = ConversationSharedMedia.photos(in: messages)
        #expect(photos.map(\.messageID) == ["m10", "m8", "m6", "m2"])
        let links = ConversationSharedMedia.links(in: messages)
        #expect(links.map(\.messageID) == ["m10", "m9"])
    }

    @Test func showMorePagesOlderHistoryUntilTheSectionFills() async throws {
        // 300 messages, a photo every 40th: the newest page (50) holds one.
        let backend = MediaBackend(total: 300, photoEvery: 40, linkEvery: 1000)
        let store = ConversationStore(backend: backend, pageSize: 50)
        store.addObserver { _ in }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let model = ConversationSharedMediaModel(store: store, photoPage: 3, linkPage: 3)
        store.addObserver { _ in model.storeDidChange() }
        #expect(model.photos.map(\.messageID) == ["m280"])
        #expect(model.hasMore(.photos))

        model.showMore(.photos) // wants 6
        try await waitUntil { model.photos.count == 6 }
        #expect(model.photos.map(\.messageID) == ["m280", "m240", "m200", "m160", "m120", "m80"])
        try await waitUntil { !model.isLoadingMore }
        // Paging stops once the section is full: nothing below m51 is loaded yet.
        #expect(store.messages.first?.seq == 51)

        model.showMore(.photos) // wants 9; only m40 remains, then history runs out
        try await waitUntil { store.older == .exhausted }
        #expect(model.photos.count == 7 && model.photos.last?.messageID == "m40")
        #expect(!model.hasMore(.photos))
    }

    @Test func showMoreSearchesAtMostFivePagesPerPress() async throws {
        let backend = MediaBackend(total: 2000, photoEvery: 100_000, linkEvery: 100_000)
        let store = ConversationStore(backend: backend, pageSize: 10)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let model = ConversationSharedMediaModel(store: store, photoPage: 3, linkPage: 3)
        store.addObserver { _ in model.storeDidChange() }
        let before = backend.historyCalls
        model.showMore(.photos)
        try await waitUntil { backend.historyCalls == before + ConversationSharedMediaModel.maxPagesPerRequest && store.older == .idle }
        #expect(backend.historyCalls == before + ConversationSharedMediaModel.maxPagesPerRequest)
        #expect(model.hasMore(.photos))
    }
}
