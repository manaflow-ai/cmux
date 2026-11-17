import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// A bare launch's message box (no remembered Chief, nothing listed yet): it takes keys before the
/// Chief's owner answers, keeps each send under its own key until the Chief is named, then hands its
/// sends (in order, once) and its draft to the real Chief; a page that goes first keeps the text.
@MainActor @Suite
struct HomeLaunchChiefTests {
    static let me = Participant(id: ParticipantID("me"), kind: .human, displayName: "Me")
    static let chief = ConversationID("conv_chief")
    static let launch = HomeLaunchChiefSource.conversation

    // MARK: The hold

    @Test func aSendBeforeTheOwnerIsReadyGoesOnceWithItsKeyAfterResolve() async throws {
        let hold = LaunchChiefHold()
        let delivered = Delivered()
        let key = IdempotencyKey.make()
        let send = Task { try await hold.hold([.text("hi")], key: key) }
        for _ in 0..<100 where hold.heldParts.isEmpty { await Task.yield() }
        #expect(hold.heldParts == [[.text("hi")]])
        #expect(delivered.all.isEmpty)
        hold.resolve(Self.chief) { delivered.add($0, $1, $2) }
        let answer = try await send.value
        #expect(answer.conversation == Self.chief)
        hold.resolve(ConversationID("conv_other")) { delivered.add($0, $1, $2) }
        // A resend of the same key gets the same answer and is not handed over again.
        _ = try await hold.hold([.text("hi")], key: key)
        #expect(delivered.all.count == 1)
        #expect(delivered.all.first?.chief == Self.chief)
        #expect(delivered.all.first?.key == key)
        #expect(hold.chief == Self.chief)
    }

    @Test func twoHeldSendsGoInTheOrderMade() async throws {
        let hold = LaunchChiefHold()
        let delivered = Delivered()
        let (first, second) = (IdempotencyKey.make(), IdempotencyKey.make())
        let one = Task { try await hold.hold([.text("one")], key: first) }
        for _ in 0..<100 where hold.heldParts.count < 1 { await Task.yield() }
        let two = Task { try await hold.hold([.text("two")], key: second) }
        for _ in 0..<100 where hold.heldParts.count < 2 { await Task.yield() }
        hold.resolve(Self.chief) { delivered.add($0, $1, $2) }
        _ = try await (one.value, two.value)
        #expect(delivered.all.map(\.key) == [first, second])
        #expect(delivered.all.map(\.parts) == [[.text("one")], [.text("two")]])
    }

    @Test func theLaunchStoresSendReachesTheHoldUnderItsIntentsKey() async throws {
        let hold = LaunchChiefHold()
        let delivered = Delivered()
        let store = Self.store(hold)
        store.start()
        defer { store.stop() }
        await store.open(Self.launch)
        for _ in 0..<1_000 where !store.isOnline { await Task.yield() }
        #expect(store.isOnline)
        let key = IdempotencyKey.make()
        let send = Task { try await store.perform(.sendMessage(conversation: Self.launch, parts: [.text("first")]), key: key) }
        for _ in 0..<1_000 where hold.heldParts.isEmpty { await Task.yield() }
        hold.resolve(Self.chief) { delivered.add($0, $1, $2) }
        _ = try await send.value
        #expect(delivered.all.map(\.key) == [key])
    }

    @Test func cancelBeforeResolveRefusesTheSendAndGivesItsTextBack() async throws {
        let hold = LaunchChiefHold()
        let send = Task { try await hold.hold([.text("held")], key: .make()) }
        for _ in 0..<100 where hold.heldParts.isEmpty { await Task.yield() }
        let launch = Self.store(hold)
        let home = Self.store(LaunchChiefHold())
        launch.setDraft("typed", for: Self.launch)
        HomeLaunchComposer.park(launch, hold: hold, in: home)
        await #expect(throws: HomeRejection.self) { try await send.value }
        #expect(home.draft(for: Self.launch) == "held\ntyped")
        #expect(launch.draft(for: Self.launch) == nil)
        // Cancelled: a later resolve hands nothing over.
        let delivered = Delivered()
        hold.resolve(Self.chief) { delivered.add($0, $1, $2) }
        #expect(hold.chief == nil)
        #expect(delivered.all.isEmpty)
    }

    // MARK: The page

    @Test func aDraftTypedBeforeResolveEndsAppendedToTheChiefsDraft() {
        let hold = LaunchChiefHold()
        let launch = Self.store(hold)
        let home = Self.store(LaunchChiefHold())
        home.setDraft("mine", for: Self.chief)
        launch.setDraft("typed at launch", for: Self.launch)
        HomeLaunchComposer.handOff(launch, hold: hold, to: Self.chief, store: home)
        #expect(home.draft(for: Self.chief) == "mine\ntyped at launch")
        #expect(launch.draft(for: Self.launch) == nil)
        #expect(hold.chief == Self.chief)
        let empty = Self.store(LaunchChiefHold())
        empty.setDraft("only this", for: Self.launch)
        HomeLaunchComposer.handOff(empty, hold: LaunchChiefHold(), to: Self.chief, store: home)
        #expect(home.draft(for: Self.chief) == "mine\ntyped at launch\nonly this")
    }

    @Test func theBoxMountsOnlyOnABareLaunch() {
        func gate(shown: ConversationID? = nil, composing: Bool = false, first: ConversationID? = nil,
                  cached: ConversationID? = nil, classic: Bool = false) -> Bool {
            HomeLaunchComposer.shows(shown: shown, composing: composing, defaultConversation: first,
                                                launchChief: cached, classic: classic)
        }
        #expect(gate())
        #expect(!gate(cached: Self.chief))
        #expect(!gate(first: Self.chief))
        #expect(!gate(classic: true))
        #expect(!gate(shown: Self.chief))
        #expect(!gate(composing: true))
    }

    @Test func theProvisionalConversationIsTheChiefsWithMe() async throws {
        let source = HomeLaunchChiefSource(me: Self.me, title: "Chief", hold: LaunchChiefHold())
        let page = try await source.snapshot(of: Self.launch, tail: 50)
        #expect(page.messages.isEmpty)
        #expect(page.conversation.title == "Chief")
        #expect(page.conversation.participants.map(\.id) == [Self.me.id, HomeLaunchChiefSource.chiefID])
        #expect(page.conversation.participants.last?.isChief == true)
        await #expect(throws: HomeRejection.self) {
            try await source.submit(HomeIntent(op: .setReadCursor(conversation: Self.launch, seq: 1)))
        }
    }

    // MARK: Quit

    @Test func quitsSaveKeepsHeldAndTypedTextForTheNextLaunchsPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-launch-chief-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let home = Self.store(LaunchChiefHold(), cache: HomeCache(url: url))
        home.start()
        let page = HomeLaunchComposer(home: home, me: Self.me, title: "Chief") { _, _ in NSView() }
        let send = Task { try await page.hold.hold([.text("held")], key: .make()) }
        for _ in 0..<100 where page.hold.heldParts.isEmpty { await Task.yield() }
        page.store.setDraft("typed", for: Self.launch)
        // Quit's save step (HomeService.flushCacheForQuit): the page's text, then Home's cache on disk.
        page.saveForQuit()
        await home.flushCache()
        // A quit can be cancelled: the page goes on holding its send.
        #expect(page.hold.heldParts == [[.text("held")]])
        #expect(!page.hold.isCancelled)
        home.stop()
        // The next launch: Home's store reads the cache, and its launch page starts with the text.
        let next = Self.store(LaunchChiefHold(), cache: HomeCache(url: url))
        next.start()
        defer { next.stop() }
        #expect(next.draft(for: Self.launch) == "held\ntyped")
        let again = HomeLaunchComposer(home: next, me: Self.me, title: "Chief") { _, _ in NSView() }
        #expect(again.store.draft(for: Self.launch) == "held\ntyped")
        #expect(next.draft(for: Self.launch) == nil)
        // A launch whose Chief answers at once mounts no page: the kept text goes to the Chief's draft.
        next.setDraft("kept", for: Self.launch)
        HomeLaunchComposer.claimParked(to: Self.chief, in: next)
        #expect(next.draft(for: Self.chief) == "kept")
        #expect(next.draft(for: Self.launch) == nil)
        page.hold.resolve(Self.chief) { _, _, _ in }
        _ = try await send.value
        again.end()
        page.end()
    }

    // MARK: Helpers

    static func store(_ hold: LaunchChiefHold, cache: HomeCache? = nil) -> HomeStore {
        HomeStore(source: HomeLaunchChiefSource(me: me, title: "Chief", hold: hold),
                  blobCacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("home-launch-chief-\(UUID().uuidString)"),
                  cache: cache, cacheWriteDelay: .zero)
    }
}

/// What the hold handed to the Chief, in order.
@MainActor
private final class Delivered {
    private(set) var all: [(chief: ConversationID, parts: [MessagePart], key: IdempotencyKey)] = []
    func add(_ chief: ConversationID, _ parts: [MessagePart], _ key: IdempotencyKey) { all.append((chief, parts, key)) }
}
