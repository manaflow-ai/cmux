import CmuxConversationCore
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileChief

/// The user, 2026-11-09: "when I open an existing chat I get shown a new chat UI until the full
/// chat loads ... Chats preserved on disk up to a storage limit, latest kept. Loading state shown
/// while loading. Apply this everywhere in the app." Home kept no rows: a launch, or a Mac chosen
/// again, showed an empty list until the Mac answered, and a conversation opened from Home showed
/// a spinner until its channel opened, then an empty conversation until its first page.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct MacHomeKeptTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "home-kept-\(UUID().uuidString)")
    }

    final class Account { var id: String? = "user-a" }

    static func feed(_ rows: MacHomeRowsCache, transcripts: ConversationTranscriptCache? = nil, account: Account) -> MacHomeFeed {
        MacHomeFeed(rowsCache: rows, transcripts: transcripts, accountID: { account.id })
    }

    /// A relaunch: the Mac's list as last read shows before the Mac answers, marked as being
    /// updated; the Mac's answer replaces it.
    @Test func aRelaunchShowsTheKeptRowsUntilTheMacAnswers() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account()
        let first = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let owner = FakeHomeOwner()
        let read = Self.feed(first, account: account)
        await read.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { read.rows?.count == 4 })
        #expect(!read.isShowingKeptRows)
        first.flush()

        // A new run: nothing in memory, the rows come from disk before any link.
        let relaunched = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let feed = Self.feed(relaunched, account: account)
        feed.showKeptRows(of: "mac-1")
        #expect(await eventually { feed.rows?.count == 4 })
        #expect(feed.rows?.map(\.id) == read.rows?.map(\.id))
        #expect(feed.isShowingKeptRows)
        #expect(HomeListNote.make(rows: feed.rows, showingKept: feed.isShowingKeptRows, homeMacID: "mac-1",
                                  macsMayExist: true, searching: false, failing: false) == .updating)

        // The Mac answers: its list, no longer the kept one.
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { !feed.isShowingKeptRows })
        #expect(feed.rows?.count == 4)
    }

    /// Another Mac chosen: that Mac's kept rows at once (from memory), never the last Mac's;
    /// another account's rows never show.
    @Test func aMacChosenAgainShowsItsOwnKeptRowsAtOnce() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account()
        let cache = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let owner = FakeHomeOwner()
        let feed = Self.feed(cache, account: account)
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { feed.rows?.count == 4 })

        // Mac 2 has nothing kept: no rows (Home says it is connecting), not Mac 1's.
        feed.forget(unless: "mac-2")
        #expect(feed.rows == nil)
        #expect(HomeListNote.make(rows: feed.rows, showingKept: false, homeMacID: "mac-2",
                                  macsMayExist: true, searching: false, failing: false) == .connecting)

        // Back to Mac 1 while it is away: its rows in the same turn.
        feed.forget(unless: "mac-1")
        #expect(feed.rows?.count == 4)
        #expect(feed.isShowingKeptRows)

        // Another account on this phone: none of them.
        account.id = "user-b"
        feed.forget(unless: "mac-2")
        feed.forget(unless: "mac-1")
        #expect(feed.rows == nil)
    }

    /// Each Mac keeps its newest rows only, and sign-out deletes them all.
    @Test func keptRowsAreBoundedAndLeaveWithTheAccount() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MacHomeRowsCache(directory: directory, rowLimit: 2, writeDelay: .milliseconds(0))
        let owner = FakeHomeOwner()
        let feed = Self.feed(cache, account: Account())
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { feed.rows?.count == 4 })
        let key = MacHomeRowsCache.key(account: "user-a", macID: "mac-1")
        #expect(cache.cached(key)?.map(\.id) == Array(feed.rows?.prefix(2).map(\.id) ?? []))
        cache.flush()
        #expect(await MacHomeRowsCache(directory: directory).load(key)?.count == 2)

        feed.discardForSignOut()
        cache.flush()
        #expect(feed.rows == nil)
        #expect(cache.cached(key) == nil)
        #expect(await MacHomeRowsCache(directory: directory).load(key) == nil)
    }

    /// No Mac yet and nothing kept: Home says it is loading instead of an empty list; with no
    /// Mac on the account it says nothing.
    @Test func homeSaysItIsLoadingRatherThanShowingNothing() {
        #expect(HomeListNote.make(rows: nil, showingKept: false, homeMacID: nil, macsMayExist: true,
                                  searching: false, failing: false) == .loading)
        #expect(HomeListNote.make(rows: nil, showingKept: false, homeMacID: nil, macsMayExist: false,
                                  searching: false, failing: false) == .none)
        #expect(HomeListNote.make(rows: [], showingKept: false, homeMacID: "m", macsMayExist: true,
                                  searching: false, failing: false) == .none)
        // A search or the retry note speaks instead.
        #expect(HomeListNote.make(rows: nil, showingKept: false, homeMacID: "m", macsMayExist: true,
                                  searching: true, failing: false) == .none)
        #expect(HomeListNote.make(rows: nil, showingKept: false, homeMacID: "m", macsMayExist: true,
                                  searching: false, failing: true) == .none)
    }

    /// A conversation opened from Home shows its kept messages before its channel opens, under
    /// its own key (never the Mac Chief's), and that same session goes live.
    @Test func aMacConversationShowsItsKeptMessagesAndGoesLiveInPlace() async throws {
        let rowsDirectory = Self.directory(), transcriptsDirectory = Self.directory()
        defer {
            try? FileManager.default.removeItem(at: rowsDirectory)
            try? FileManager.default.removeItem(at: transcriptsDirectory)
        }
        let transcripts = ConversationTranscriptCache(directory: transcriptsDirectory)
        defer { transcripts.removeAll() }
        let owner = FakeHomeOwner()
        let feed = Self.feed(MacHomeRowsCache(directory: rowsDirectory), transcripts: transcripts, account: Account())
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { feed.rows?.count == 4 })

        let key = try #require(feed.transcriptKey("conv_ops"))
        #expect(key != "mac:mac-1")
        let kept = (1...3).map { ConversationMessage(id: "m\($0)", seq: $0, clientMessageID: nil, senderID: "agent_codex",
                                                     sentAt: Date(timeIntervalSince1970: Double($0)), text: "kept \($0)") }
        transcripts.save(key, info: nil, meID: "user_local", messages: kept)

        let route = MacConversationRoute(conversationID: "conv_ops", chief: nil, title: "Ops")
        let shown = try #require(feed.keptSession(for: route))
        // In the same turn: no spinner, no empty conversation.
        #expect(shown.lastMessage?.id == "m3")
        #expect(shown.unavailableTitle == MacHomeFeed.keptTitle)
        #expect(feed.keptSession(for: route) === shown)

        let live = try await feed.session(for: route)
        #expect(live === shown)
        #expect(live.unavailableTitle == nil)
        #expect(live.identity.chiefID == "agent_codex")
        // Nothing kept for another account's key.
        #expect(transcripts.cached("mac:mac-1") == nil)
    }
}
