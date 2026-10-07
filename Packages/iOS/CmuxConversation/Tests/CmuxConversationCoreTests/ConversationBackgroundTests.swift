import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationBackgroundModelTests {
    @Test func luminanceFollowsWCAGAndPicksTheDarkStyleWhereWhiteTextContrastsMore() {
        #expect(ConversationBackground.relativeLuminance(hex: "#FFFFFF") == 1)
        #expect(ConversationBackground.relativeLuminance(hex: "#000000") == 0)
        #expect(ConversationBackground.relativeLuminance(hex: "nope") == nil)
        // White and black text have equal contrast at the threshold.
        let t = ConversationBackground.darkContentThreshold
        #expect(abs(1.05 / (t + 0.05) - (t + 0.05) / 0.05) < 1e-9)
        let dusk = ConversationBackgroundLook.named("sky.dusk")!
        let ice = ConversationBackgroundLook.named("color.ice")!
        #expect(ConversationBackgroundDraft(look: dusk).optimisticBackground(id: "x", setBy: nil).prefersDarkContent)
        #expect(!ConversationBackgroundDraft(look: ice).optimisticBackground(id: "x", setBy: nil).prefersDarkContent)
    }

    @Test func auroraAndGlitterAreAsDarkAsTheirBase() {
        // Their bright accents are small; the base fills the screen.
        for look in ConversationBackgroundLook.all where look.kind == .aurora || look.kind == .glitter {
            #expect(look.luminance < ConversationBackground.darkContentThreshold, "\(look.id) L=\(look.luminance)")
        }
        #expect(ConversationBackground.luminance(kind: .color, colors: ["#000000", "#FFFFFF"]) == 0.5)
    }

    @Test func everyLookHasValidColorsAndAName() {
        for look in ConversationBackgroundLook.all {
            #expect(!look.colors.isEmpty && look.colors.allSatisfy { ConversationBackground.rgb(hex: $0) != nil }, "\(look.id)")
            #expect(look.id.hasPrefix(look.kind.rawValue + "."), "\(look.id)")
            #expect(ConversationBackgroundStrings.name(look) != ConversationBackgroundStrings.name(look.kind), "\(look.id) has its own name")
        }
        #expect(Set(ConversationBackgroundLook.all.map(\.id)).count == ConversationBackgroundLook.all.count)
    }

    @Test func noticeStripsChatKitEmphasisMarkers() {
        let mine = ConversationBackgroundStrings.emphasized("#You# changed the background.")
        #expect(mine.text == "You changed the background.")
        #expect(mine.emphasis.map { String(mine.text[$0]) } == "You")
        let ja = ConversationBackgroundStrings.emphasized("#あなた#が背景を変更しました。")
        #expect(ja.text == "あなたが背景を変更しました。")
        #expect(ja.emphasis.map { String(ja.text[$0]) } == "あなた")
        #expect(ConversationBackgroundStrings.emphasized("plain").emphasis == nil)
    }

    @Test func noticeNamesTheActorByFirstName() {
        let info = ConversationInfo(id: "g", title: "cmux", kind: .group, participants: [
            ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
            ConversationParticipant(id: "leo", name: "Leo Li", initials: "LL", colorHex: "#BF5AF2", isMe: false),
        ])
        let theirs = ConversationBackgroundStrings.notice(.backgroundRemoved, senderID: "leo", meID: "me", info: info)
        #expect(theirs.text == "Leo removed the background.")
        #expect(theirs.emphasis.map { String(theirs.text[$0]) } == "Leo")
        #expect(ConversationBackgroundStrings.notice(.backgroundChanged, senderID: "me", meID: "me", info: info).text == "You changed the background.")
    }

    @Test func wireDecodingReadsBackgroundsAndSystemLines() throws {
        let base = URL(string: "http://127.0.0.1:4870")!
        let info = try #require(WireDecoding.conversation([
            "id": "d", "title": "John", "kind": "direct", "participants": [],
            "background": ["id": "bg_1", "kind": "photo", "photo": ["url": "/media/up_1.png", "width": 1179, "height": 2556], "luminance": 0.3, "setBy": "john"],
        ], base: base))
        let background = try #require(info.background)
        #expect(background.kind == .photo && background.luminance == 0.3 && background.setBy == "john")
        #expect(background.photo?.url?.absoluteString == "http://127.0.0.1:4870/media/up_1.png")
        #expect(background.photo?.width == 1179)
        // A photo without its image is dropped; a look without luminance derives it.
        #expect(WireDecoding.background(["id": "x", "kind": "photo"], base: base) == nil)
        let derived = WireDecoding.background(["id": "x", "kind": "color", "colors": ["#000000", "#FFFFFF"]], base: base)
        #expect(derived?.luminance == 0.5)
        #expect(WireDecoding.conversation(["id": "d"])?.background == nil)
        let line = WireDecoding.message(["id": "m", "seq": 3, "senderId": "john", "text": "", "system": "backgroundChanged"], base: base)
        #expect(line?.systemEvent == .backgroundChanged && line?.isNotice == true)
        let draft = WireDecoding.wireBackground(ConversationBackgroundDraft(kind: .photo, attachmentID: "up_1", luminance: 0.25))
        #expect(draft["kind"] as? String == "photo" && draft["attachmentId"] as? String == "up_1" && draft["luminance"] as? Double == 0.25)
        #expect(draft["colors"] == nil)
    }

    @Test func aSystemLineEndsTheRunAndKeepsMyStatus() {
        func message(_ seq: Int, _ sender: String, delivery: ConversationDelivery? = nil, system: ConversationSystemEvent? = nil) -> ConversationMessage {
            ConversationMessage(
                id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: sender, sentAt: Date(timeIntervalSince1970: Double(seq) * 10),
                text: system == nil ? "x" : "", delivery: delivery, systemEvent: system
            )
        }
        let plan = ConversationRunPlan(messages: [
            message(1, "me", delivery: .delivered), message(2, "lc", system: .backgroundChanged), message(3, "me", delivery: .sent),
        ], meID: "me")
        #expect(plan.entries[0].isLastInRun && plan.entries[2].isFirstInRun)
        #expect(plan.entries[0].status != .none)
    }
}

@MainActor
@Suite struct ConversationStoreBackgroundTests {
    @Test func settingShowsAtOnceThenTakesTheServersBackground() async throws {
        let backend = BackgroundBackend()
        backend.hold = true
        let store = ConversationStore(backend: backend)
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        #expect(store.supportsBackgrounds)

        store.setBackground(ConversationBackgroundDraft(look: ConversationBackgroundLook.named("aurora.green")!))
        #expect(store.background?.kind == .aurora)
        #expect(store.background?.id.hasPrefix("local:") == true)
        #expect(store.background?.setBy == "me")
        #expect(changes.last == .background)
        // A push of the old state while mine is in flight does not flicker it away.
        store.apply(.conversationChanged(backend.info))
        #expect(store.background?.kind == .aurora)
        backend.release()
        try await waitUntil { store.background?.id == "srv_1" }
        #expect(backend.received.first??.look == "aurora.green")
    }

    @Test func aRefusedBackgroundRollsBack() async throws {
        let backend = BackgroundBackend()
        backend.fail = true
        let store = ConversationStore(backend: backend)
        var current = backend.info
        current.background = ConversationBackground(id: "old", kind: .color, colors: ["#FFFFFF"], luminance: 1)
        store.apply(.connected(info: current, meID: "me", lagged: false))
        var rejection: ConversationBackendError?
        store.setBackground(nil) { rejection = $0 }
        #expect(store.background == nil)
        try await waitUntil { store.background?.id == "old" }
        #expect(rejection != nil)
    }

    @Test func aPhotoKeepsItsPickedBytesThroughConfirmationAndRedelivery() async throws {
        let backend = BackgroundBackend()
        let store = ConversationStore(backend: backend)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        let bytes = Data([1, 2, 3])
        store.setBackgroundPhoto(bytes, mimeType: "image/png", width: 30, height: 60, luminance: 0.2)
        #expect(store.background?.photo?.localData == bytes)
        try await waitUntil { store.background?.id == "srv_1" }
        #expect(store.background?.photo?.localData == bytes)
        #expect(store.background?.photo?.url != nil)
        #expect(backend.received.first??.attachmentID == "up_1")
        // The server's broadcast of the same background keeps the local copy.
        var pushed = backend.info
        pushed.background = backend.lastConfirmed
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.apply(.conversationChanged(pushed))
        #expect(store.background?.photo?.localData == bytes)
        #expect(!changes.contains(.background))
        // Someone else's background replaces it and is announced.
        pushed.background = ConversationBackground(id: "theirs", kind: .glitter, colors: ["#000000"], luminance: 0.01, setBy: "lc")
        store.apply(.conversationChanged(pushed))
        #expect(store.background?.id == "theirs")
        #expect(changes.contains(.background))
    }

    @Test func systemLinesFromOthersAreNotUnreadAndCannotBeEdited() async throws {
        let backend = ScriptedBackend(total: 10)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.apply(.readState(ConversationReadState(lastReadSeq: 10, unreadCount: 0, headSeq: 10)))
        var line = backend.makeMessage(seq: 11, sender: "lc")
        line.text = ""
        line.systemEvent = .backgroundChanged
        store.apply(.message(line, eventSeq: 1))
        #expect(store.unreadCount == 0)
        var mine = backend.makeMessage(seq: 12, sender: "me")
        mine.text = ""
        mine.systemEvent = .backgroundRemoved
        store.apply(.message(mine, eventSeq: 2))
        #expect(!store.canEdit(mine) && !store.canUnsend(mine))
    }

    @Test func backendsWithoutBackgroundsHideThePicker() async {
        let backend = ListStateBackend()
        #expect(!backend.supportsBackgrounds)
        await #expect(throws: ConversationBackendError.self) {
            _ = try await backend.setBackground(nil)
        }
    }
}

/// Sets backgrounds like the server, optionally holding or failing them.
final class BackgroundBackend: ConversationBackgroundBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "d", title: "John", kind: .direct, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#30B0C7", isMe: false),
    ])
    private let lock = NSLock()
    private var _hold = false
    private var _fail = false
    private var _received: [ConversationBackgroundDraft?] = []
    private var _lastConfirmed: ConversationBackground?
    private var _waiters: [CheckedContinuation<Void, Never>] = []
    private var _count = 0

    var hold: Bool { get { lock.withLock { _hold } } set { lock.withLock { _hold = newValue } } }
    var fail: Bool { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
    var received: [ConversationBackgroundDraft?] { lock.withLock { _received } }
    var lastConfirmed: ConversationBackground? { lock.withLock { _lastConfirmed } }

    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _hold = false
            defer { _waiters = [] }
            return _waiters
        }
        waiters.forEach { $0.resume() }
    }

    func setConversationBackground(_ draft: ConversationBackgroundDraft?) async throws -> ConversationInfo {
        let held = lock.withLock { () -> Bool in
            _received.append(draft)
            return _hold
        }
        if held {
            await withCheckedContinuation { waiter in
                let resumeNow = lock.withLock { () -> Bool in
                    guard _hold else { return true }
                    _waiters.append(waiter)
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        }
        if fail { throw ConversationBackendError(code: -32602, message: "background") }
        var result = info
        result.background = lock.withLock { () -> ConversationBackground? in
            _count += 1
            _lastConfirmed = draft.map {
                var background = $0.optimisticBackground(id: "srv_\(_count)", setBy: "me")
                if $0.kind == .photo, let id = $0.attachmentID {
                    background.photo = ConversationBackground.Photo(url: URL(string: "http://sim/media/\(id).png"), width: 30, height: 60)
                }
                return background
            }
            return _lastConfirmed
        }
        return result
    }

    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        ConversationAttachment(id: "up_1", kind: .image, width: 30, height: 60, url: URL(string: "http://sim/media/up_1.png"))
    }

    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { _ in } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(messages: [], hasMore: false)
    }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func unsend(messageID: String) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func close() {}
}
