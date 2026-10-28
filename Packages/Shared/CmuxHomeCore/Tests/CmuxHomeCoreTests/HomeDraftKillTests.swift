import Darwin
import Foundation
import Testing
@testable import CmuxHomeCore

/// A Home draft survives a forced end of the app (audit 4, P15): a crash, a SIGKILL, a power loss or
/// an Activity Monitor force quit runs no quit step, so the coalesced cache batch (250 ms in the app)
/// never reaches disk. The draft is saved as it is typed, through a write-ahead record beside the
/// cache, and the next launch's cache read puts it back. A real SIGKILL ends a child process (a
/// Swift Testing exit test) right after the keystroke; the parent reads the cache as a relaunch does.
@Suite struct HomeDraftKillTests {
    static let austin = ConversationID("conv_austin")

    /// The child's cache folder: named by the parent test process, so parallel runs never share one.
    static func folder(parent: pid_t) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-kill-\(parent)", isDirectory: true)
    }

    @Test func aDraftTypedJustBeforeASIGKILLIsThereAtTheNextLaunch() async throws {
        let folder = Self.folder(parent: getpid())
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(processExitsWith: .signal(SIGKILL)) {
            await HomeDraftKillTests.typeThenDie(in: HomeDraftKillTests.folder(parent: getppid()))
        }
        let relaunch = HomeCache(url: folder.appendingPathComponent("home.json"))
        #expect(relaunch.load()?.drafts[Self.austin] == "half a thought")
    }

    /// The child: one keystroke's draft, then a SIGKILL a moment later (no quit step, no flush, no deinit).
    @MainActor static func typeThenDie(in folder: URL) async {
        let cache = HomeCache(url: folder.appendingPathComponent("home.json"))
        // The app's batch would write in 250 ms; this one never does before the kill.
        let view = HomeClientViewCache(cache: cache, writeDelay: .seconds(3_600), clock: ContinuousClock())
        view.setDraft("half a thought", for: austin)
        try? await Task.sleep(for: .milliseconds(200))
        withExtendedLifetime(view) { _ = kill(getpid(), SIGKILL) }
    }

    static func cache() -> HomeCache {
        HomeCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-journal-\(UUID().uuidString)/home.json"))
    }

    /// A write that holds the typed changes empties the record: it keeps only what the index does not have.
    @MainActor @Test func aWriteThatReachedDiskEmptiesTheRecord() async throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .seconds(3_600), clock: ContinuousClock())
        view.restore(nil) { _ in }
        view.setDraft("half", for: Self.austin)
        view.setDraft("half a thought", for: Self.austin)
        await cache.draftJournal.idle()
        #expect(FileManager.default.fileExists(atPath: cache.draftJournal.url.path))
        await view.flush()
        await cache.draftJournal.idle()
        #expect(!FileManager.default.fileExists(atPath: cache.draftJournal.url.path))
        #expect(cache.load()?.drafts[Self.austin] == "half a thought")
    }

    /// A line cut short by the end of the process is skipped, and the next launch's lines still read.
    @MainActor @Test func aLineCutShortIsSkippedAndTheNextLaunchAppendsAfterIt() async throws {
        let cache = Self.cache()
        let journal = cache.draftJournal
        try FileManager.default.createDirectory(at: journal.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let whole = Array(#"{"c":"conv_austin","n":1,"t":"kept"}"#.utf8) + [0x0A]
        let cut = Array(#"{"c":"conv_austin","n":2,"t":"cut sh"#.utf8)
        try Data(whole + cut).write(to: journal.url)
        #expect(cache.load()?.drafts[Self.austin] == "kept")
        let other = ConversationID("conv_other")
        journal.record("after the relaunch", for: other)
        await journal.idle()
        let drafts = cache.load()?.drafts
        #expect(drafts?[Self.austin] == "kept")
        #expect(drafts?[other] == "after the relaunch")
    }

    /// The earlier launch's lines stay until a write made after the restore (which replayed them) holds them.
    @MainActor @Test func theEarlierLaunchsLinesStayUntilARestoredWriteHoldsThem() async throws {
        let cache = Self.cache()
        let first = HomeClientViewCache(cache: cache, writeDelay: .seconds(3_600), clock: ContinuousClock())
        first.setDraft("from the last launch", for: Self.austin)
        await cache.draftJournal.idle()
        // The relaunch: a new cache object on the same files, restored from what they hold.
        let again = HomeCache(url: cache.url)
        let view = HomeClientViewCache(cache: again, writeDelay: .seconds(3_600), clock: ContinuousClock())
        view.restore(again.load()) { _ in }
        #expect(view.drafts[Self.austin] == "from the last launch")
        view.setScrollAnchor(HomeScrollAnchor(message: MessageID("msg_1"), offset: 3), for: Self.austin)
        await view.flush()
        await again.draftJournal.idle()
        #expect(!FileManager.default.fileExists(atPath: again.draftJournal.url.path))
        #expect(again.load()?.drafts[Self.austin] == "from the last launch")
    }
}
