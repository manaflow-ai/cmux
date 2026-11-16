import Foundation
import Testing
@testable import CmuxMobileLive

/// The pairing of a terminal's agent session with its chat, and the face each tab shows, kept on
/// disk beside the transcripts: a relaunch reads them (with the Mac out of reach too), each account
/// and Mac keeps its own, and sign-out deletes them with the transcripts.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct KeptTerminalChatsTests {
    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "kept-terminal-chats-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func cache(_ directory: URL) -> AgentTranscriptCache {
        AgentTranscriptCache(directory: directory, writeDelay: .milliseconds(0))
    }

    @Test func aRelaunchReadsThePairingAndTheFaceFromDisk() async throws {
        let directory = Self.folder()
        let kept = Self.cache(directory).terminalChats
        let file = kept.file
        defer { try? FileManager.default.removeItem(at: file) }
        let chatKey = try #require(KeptTerminalChats.key("acct", "mac", "claude", "h-1"))
        let faceKey = try #require(KeptTerminalChats.key("acct", "mac", "s2"))
        kept.keepChat("a-1", for: chatKey)
        kept.keepFace(showsChat: false, for: faceKey)
        await kept.flush()
        // Beside the transcripts' folder, never in it (the folder's byte trim would delete it).
        #expect(kept.file.deletingLastPathComponent() == directory.deletingLastPathComponent())

        // Relaunch: a fresh cache, nothing in memory; the cold read is timed.
        let relaunched = Self.cache(directory).terminalChats
        #expect(relaunched.chat(chatKey) == nil)
        let started = ContinuousClock.now
        await relaunched.load()
        let elapsed = (ContinuousClock.now - started).components
        let line = "OFFLINECHAT pairing_cold_read_ms=\(String(format: "%.2f", Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15))"
        print(line)
        Attachment.record(line, named: "offlinechat-pairing.txt")
        #expect(relaunched.chat(chatKey) == "a-1")
        #expect(relaunched.showsChat(faceKey) == false)
        // Another account or Mac keeps none of it.
        #expect(relaunched.chat(try #require(KeptTerminalChats.key("other", "mac", "claude", "h-1"))) == nil)
        #expect(relaunched.chat(try #require(KeptTerminalChats.key("acct", "mac2", "claude", "h-1"))) == nil)
        #expect(KeptTerminalChats.key("", "mac", "claude", "h-1") == nil)
        #expect(KeptTerminalChats.key("", "mac", "s2") == nil)

        // A stale pairing is forgotten, and stays forgotten after a relaunch.
        relaunched.keepChat(nil, for: chatKey)
        await relaunched.flush()
        let again = Self.cache(directory).terminalChats
        await again.load()
        #expect(again.chat(chatKey) == nil)
        #expect(again.showsChat(faceKey) == false)
    }

    /// A pairings file from a build that kept no faces (only `chats`) still reads, pairings and all.
    @Test func aFileFromABuildWithoutFacesKeepsItsPairings() async throws {
        let file = Self.folder().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let older = #"{"chats":{"acct|mac|claude|h-1":{"value":"a-1","at":1}}}"#
        try Data(older.utf8).write(to: file)
        let kept = KeptTerminalChats(file: file, queue: DispatchQueue(label: "kept-terminal-chats-older"))
        await kept.load()
        #expect(kept.chat("acct|mac|claude|h-1") == "a-1")
        #expect(kept.showsChat("acct|mac|s1") == nil)
    }

    @Test func signOutDeletesThePairingsWithTheTranscripts() async throws {
        let directory = Self.folder()
        let cache = Self.cache(directory)
        let key = try #require(KeptTerminalChats.key("acct", "mac", "codex", "h-2"))
        cache.terminalChats.keepChat("w-9", for: key)
        await cache.terminalChats.flush()
        #expect(FileManager.default.fileExists(atPath: cache.terminalChats.file.path(percentEncoded: false)))

        cache.removeAll()
        #expect(cache.terminalChats.chat(key) == nil)
        cache.flush()
        #expect(!FileManager.default.fileExists(atPath: cache.terminalChats.file.path(percentEncoded: false)))
        let relaunched = Self.cache(directory).terminalChats
        await relaunched.load()
        #expect(relaunched.chat(key) == nil)
    }

    @Test func eachKindKeepsItsNewestEntriesUpToItsLimit() async throws {
        let file = Self.folder().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let queue = DispatchQueue(label: "kept-terminal-chats-test")
        // Entries stamped in order: the oldest goes first.
        let stamped = KeptTerminalChats(file: file, limit: 2, queue: queue, now: Self.ticking())
        await stamped.load()
        for chat in ["a", "b", "c"] { stamped.keepChat(chat, for: "k-\(chat)") }
        for tab in ["s1", "s2", "s3"] { stamped.keepFace(showsChat: tab != "s3", for: "f-\(tab)") }
        await stamped.flush()
        let read = KeptTerminalChats(file: file, limit: 2, queue: queue)
        await read.load()
        #expect(read.chat("k-a") == nil)
        #expect(read.chat("k-b") == "b")
        #expect(read.chat("k-c") == "c")
        #expect(read.showsChat("f-s1") == nil)
        #expect(read.showsChat("f-s2") == true)
        #expect(read.showsChat("f-s3") == false)
    }

    /// A clock that moves one second per read.
    static func ticking() -> @Sendable () -> Date {
        let tick = Tick()
        return { tick.next() }
    }

    final class Tick: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 0.0
        func next() -> Date {
            lock.withLock {
                seconds += 1
                return Date(timeIntervalSince1970: seconds)
            }
        }
    }
}
