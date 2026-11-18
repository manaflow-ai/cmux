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

    /// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
    /// faster/percievably load faster". A relaunch draws the kept rows in the first frame: they
    /// are on the feed in the same turn as `showKeptRows`, with no await. Before, they came from a
    /// disk read off the main thread, so Home's first frame said "Connecting to <Mac>…".
    @Test func aRelaunchHasTheKeptRowsInTheFirstFrame() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account()
        let first = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let owner = FakeHomeOwner()
        let read = Self.feed(first, account: account)
        await read.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { read.rows?.count == 4 })
        first.flush()

        let relaunched = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let feed = Self.feed(relaunched, account: account)
        feed.showKeptRows(of: "mac-1")
        #expect(feed.rows?.map(\.id) == read.rows?.map(\.id), "the kept rows, in this turn")
        #expect(feed.isShowingKeptRows)
        #expect(HomeListNote.make(rows: feed.rows, showingKept: feed.isShowingKeptRows, homeMacID: "mac-1",
                                  macsMayExist: true, searching: false, failing: false) != .connecting)
    }

    /// The first frame reads only the head: the first `firstScreenRows` of 200 kept rows. The
    /// whole kept list follows off the main thread and takes their place.
    @Test func theFirstFrameReadsOnlyTheHeadThenTheWholeKeptList() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = MacHomeRowsCache.key(account: "user-a", macID: "mac-1")
        let writer = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        writer.save(key, rows: HomeKeptRowsTimingTests.rows(200))
        writer.flush()

        let relaunched = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        #expect(relaunched.firstScreen(key)?.count == MacHomeRowsCache.firstScreenRows)
        let feed = Self.feed(relaunched, account: Account())
        feed.showKeptRows(of: "mac-1")
        #expect(feed.rows?.count == MacHomeRowsCache.firstScreenRows)
        #expect(await eventually { feed.rows?.count == 200 })
        #expect(feed.isShowingKeptRows)
    }

    /// The Mac's first window stays when it lands before the whole kept list. A relaunch draws the
    /// kept head (40 of 200 rows); the Mac's first window (20 rows) arrives and the head's other
    /// rows stay below it, so the rows on screen equal the head again, now as the Mac's (not
    /// kept, not saved: the list is not complete). The whole kept list read after must not
    /// replace them and mark them kept again. Before, the late read checked only that the rows
    /// still equalled the head. The Mac's whole list is held back, as on a slow link.
    @Test func theMacsFirstWindowIsNotReplacedByTheLateKeptList() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account()
        let wire: [[String: Any]] = (0..<200).map { index in
            ["id": "conv_\(index)", "owner": "local", "kind": "channel", "name": "Channel \(index)", "unread": 0,
             "activity_at": String(format: "2026-10-21T%02d:%02d:00Z", 23 - index / 60, 59 - index % 60),
             "pinned": false, "marked_unread": false, "muted": false]
        }
        let key = MacHomeRowsCache.key(account: "user-a", macID: "mac-1")
        let writer = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        writer.save(key, rows: wire.compactMap(MacHomeRow.init(wire:)))
        writer.flush()

        let owner = FakeHomeOwner(windows: .honors, rows: wire)
        let relaunched = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        // Hold the whole kept list's disk read until the Mac's first window has landed.
        let held = DispatchSemaphore(value: 0)
        relaunched.queue.async { held.wait() }
        let feed = Self.feed(relaunched, account: account)
        feed.showKeptRows(of: "mac-1")
        let head = feed.rows?.map(\.id)
        #expect(head?.count == MacHomeRowsCache.firstScreenRows)
        await feed.connect(link: MockMacLink { _, request in
            // The whole list (a home-inbox with no window) never answers here: only the first window.
            if let object = try? JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any],
               object["cmd"] as? String == "home-inbox", object["limit"] == nil, object["ids"] == nil { return [] }
            return owner.respond(request)
        }, macID: "mac-1")
        #expect(await eventually { !feed.isShowingKeptRows })
        let answered = feed.rows?.map(\.id)
        #expect(answered == head, "the Mac's first window over the head's other rows: the head, row for row")

        held.signal()
        // The read is done once the queue runs a block after it.
        await withCheckedContinuation { done in relaunched.queue.async { done.resume() } }
        for _ in 0..<50 { await Task.yield() }
        #expect(feed.rows?.map(\.id) == answered, "the Mac's rows, not the 200 kept")
        #expect(!feed.isShowingKeptRows)
    }

    /// Back-compat: a list kept by an app before head files (only `<key>.json` on disk) still
    /// shows after the update's first launch, read off the main thread as before, and its next
    /// save writes the head for the launch after.
    @Test func aListKeptBeforeHeadFilesStillShows() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = MacHomeRowsCache.key(account: "user-a", macID: "mac-1")
        let writer = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        writer.save(key, rows: HomeKeptRowsTimingTests.rows(200))
        writer.flush()
        // What an older app left: the list file alone.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for head in files where head.lastPathComponent.hasSuffix(".head.json") { try FileManager.default.removeItem(at: head) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).count == 1)

        let relaunched = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        #expect(relaunched.firstScreen(key) == nil)
        let feed = Self.feed(relaunched, account: Account())
        feed.showKeptRows(of: "mac-1")
        #expect(await eventually { feed.rows?.count == 200 })
        #expect(feed.isShowingKeptRows)

        // The next save writes the head too: the launch after draws it in the first frame.
        relaunched.save(key, rows: HomeKeptRowsTimingTests.rows(199))
        relaunched.flush()
        #expect(MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0)).firstScreen(key)?.count
                == MacHomeRowsCache.firstScreenRows)
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
        // No bar while its channel opens (Leo, 2026-11-16: a reconnect says nothing).
        #expect(shown.barItem == nil)
        #expect(feed.keptSession(for: route) === shown)

        let live = try await feed.session(for: route)
        #expect(live === shown)
        #expect(live.unavailableTitle == nil)
        #expect(live.identity.chiefID == "agent_codex")
        // Nothing kept for another account's key.
        #expect(transcripts.cached("mac:mac-1") == nil)
    }

    @Test func nothingKeptGivesNoSessionUnlessAnEmptyOneIsAsked() {
        // New Message keeps its blank page (nil); a failed open asks for an empty session instead.
        let feed = MacHomeFeed(rowsCache: nil, transcripts: nil, accountID: { nil })
        let route = MacConversationRoute(conversationID: "c-none", chief: nil, title: "Nothing kept")
        #expect(feed.keptSession(for: route) == nil)
        let empty = feed.keptSession(for: route, orEmpty: true)
        #expect(empty != nil)
        #expect(empty?.lastMessage == nil)
    }

    /// The head files (`<key>.head.json`, #43289) are bounded and trimmed with the lists. Each
    /// holds at most `firstScreenRows` rows, the list's own first rows. They count toward the one
    /// byte limit for every account and Mac (`byteLimit`, 2 MiB in the app), and the oldest
    /// lists and heads go first. Sign-out removes every one. The sizes print as `HEADBOUND` for
    /// the PR: the default 200-row list with these previews, its head, and the directory.
    @Test func theHeadFilesAreBoundedAndTrimmedWithTheLists() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func files() -> [URL: Int] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
        }
        func name(_ key: String) -> String { key.replacingOccurrences(of: "|", with: "_") }

        // One list at the app's limits: its head is a small, bounded file next to it.
        let one = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let key = MacHomeRowsCache.key(account: "user-a", macID: "mac-0")
        let rows = HomeKeptRowsTimingTests.rows(MacHomeRowsCache.rowLimit + 50)
        one.save(key, rows: rows)
        one.flush()
        let sized = files()
        let head = try #require(sized.first { $0.key.lastPathComponent.hasSuffix(".head.json") })
        let list = try #require(sized.first { !$0.key.lastPathComponent.hasSuffix(".head.json") })
        let headRows = try JSONDecoder().decode([MacHomeRow].self, from: Data(contentsOf: head.key))
        #expect(headRows == Array(rows.prefix(MacHomeRowsCache.firstScreenRows)), "the list's own first rows")
        let listRows = try JSONDecoder().decode([MacHomeRow].self, from: Data(contentsOf: list.key))
        #expect(listRows.count == MacHomeRowsCache.rowLimit)
        print("HEADBOUND one-mac rows=\(listRows.count) list_bytes=\(list.value) head_rows=\(headRows.count) head_bytes=\(head.value) byte_limit=\(MacHomeRowsCache.byteLimit)")
        #expect(head.value * MacHomeRowsCache.rowLimit <= list.value * MacHomeRowsCache.firstScreenRows + 4096,
                "a head is the first 40 of 200 rows: about a fifth of its list")

        // Many Macs past a small limit: the directory stays under it, heads included, and the
        // oldest lists and their heads are trimmed first.
        try FileManager.default.removeItem(at: directory)
        let limit = 4 * list.value
        let small = MacHomeRowsCache(directory: directory, byteLimit: limit, writeDelay: .milliseconds(0))
        let keys = (0..<12).map { MacHomeRowsCache.key(account: "user-a", macID: "mac-\($0)") }
        for each in keys {
            small.save(each, rows: rows)
            small.flush()
            // Distinct modification times, so the trim's oldest-first order is the save order.
            Thread.sleep(forTimeInterval: 0.02)
        }
        let after = files()
        let total = after.values.reduce(0, +)
        let heads = after.keys.filter { $0.lastPathComponent.hasSuffix(".head.json") }
        print("HEADBOUND twelve-macs byte_limit=\(limit) dir_bytes=\(total) files=\(after.count) heads=\(heads.count)")
        #expect(total <= limit, "lists and heads together within the byte limit")
        let newest = name(keys.last!)
        #expect(after.keys.contains { $0.lastPathComponent == "\(newest).json" }, "the newest list stays")
        #expect(after.keys.contains { $0.lastPathComponent == "\(newest).head.json" }, "and its head")
        let oldest = name(keys.first!)
        #expect(!after.keys.contains { $0.lastPathComponent.hasPrefix(oldest + ".") }, "the oldest list and head are trimmed")
        for head in heads {
            let count = try JSONDecoder().decode([MacHomeRow].self, from: Data(contentsOf: head)).count
            #expect(count <= MacHomeRowsCache.firstScreenRows)
        }

        // Sign-out: no list and no head stays.
        small.removeAll()
        small.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }
}
