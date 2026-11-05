import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The disk tier under the host's chat tails (``AgentPaneTailDisk``): a chat opened in a new tab
/// from the sidebar or a link, or after the app restarted, answers `chat.tail.get` with what a page
/// last read of it, local chats included, instead of nothing (Leo, 2026-11-05: "There's no reason
/// for them to have a delay, even under load."). Bounded like the memory tier, cleared on sign-out.
@Suite(.serialized)
@MainActor
struct ChatTailDiskTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "chat-tail-disk-\(UUID().uuidString)")
    }

    private static func withDisk(_ body: (AgentPaneTailDisk) async throws -> Void) async rethrows {
        let cache = AgentPaneTailCache.shared
        cache.clear()
        cache.resume()
        let disk = AgentPaneTailDisk(directory: folder())
        let before = cache.disk
        cache.disk = disk
        defer {
            cache.disk = before
            cache.clear()
            cache.resume()
            try? FileManager.default.removeItem(at: disk.directory)
        }
        try await body(disk)
    }

    private static func json(_ tail: [String: Any]) -> JSONValue {
        JSONValue(foundation: tail)!
    }

    private static func get(_ session: String) async -> Any? {
        ChatTailCacheTests.value(await AgentPaneTailCache.reply(to: "chat.tail.get", params: ["sessionId": session], host: nil))
    }

    /// A local chat an earlier launch read: memory is empty (the app restarted), the file is there,
    /// and the open draws it rather than waiting for acpmux's attach.
    @Test func aChatAnEarlierLaunchReadAnswersFromDisk() async {
        await Self.withDisk { disk in
            disk.write(Self.json(ChatTailCacheTests.tail(5)), for: "local-1")
            await disk.settled()
            #expect(AgentPaneTailCache.shared.tail(for: "local-1") == nil)
            #expect(ChatTailCacheTests.seqs(await Self.get("local-1")) == [1, 2, 3, 4, 5])
            // Read back once, then held in memory: the next open is a memory hit.
            #expect(AgentPaneTailCache.shared.tail(for: "local-1") != nil)
        }
    }

    /// A tail a page hands over is saved, off the main thread, for the next launch.
    @Test func aHandedOverTailIsSavedForTheNextLaunch() async {
        await Self.withDisk { disk in
            _ = ChatTailCacheTests.bridge("chat.tail", ["sessionId": "s-1", "tail": ChatTailCacheTests.tail(3)])
            await disk.settled()
            #expect(ChatTailCacheTests.seqs((await disk.read("s-1"))?.foundationObject) == [1, 2, 3])
            // A page that no longer stands behind the chat forgets it on disk too.
            _ = ChatTailCacheTests.bridge("chat.tail", ["sessionId": "s-1"])
            #expect(await disk.read("s-1") == nil)
        }
    }

    /// The newest hand-over wins: a burst of saves of one chat reads back as the last.
    @Test func theNewestSaveWins() async {
        await Self.withDisk { disk in
            for count in 1...8 { disk.write(Self.json(ChatTailCacheTests.tail(count)), for: "s-1") }
            #expect(ChatTailCacheTests.seqs((await disk.read("s-1"))?.foundationObject) == Array(1...8))
        }
    }

    /// Sign-out clears the disk tier with the memory one: no later launch draws the old account's chats.
    @Test func signOutClearsTheDisk() async {
        await Self.withDisk { disk in
            _ = ChatTailCacheTests.bridge("chat.tail", ["sessionId": "s-1", "tail": ChatTailCacheTests.tail(3)])
            AgentPaneTailCache.shared.clear()
            AgentPaneTailCache.shared.resume()
            #expect(await disk.read("s-1") == nil)
            #expect(await Self.get("s-1") is NSNull)
        }
    }

    /// Bounded as memory is: the most recent ``AgentPaneTailCache/chats`` chats, and a file over the
    /// byte bound (or no tail at all) is read as none and removed.
    @Test func theDiskIsBounded() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AgentPaneTailDisk(directory: directory, files: 3, bytes: 4096)
        for index in 0..<5 {
            disk.write(Self.json(ChatTailCacheTests.tail(2)), for: "s-\(index)")
            await disk.settled()
            // Distinct modification dates, so the oldest is the one trimmed.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))],
                                                  ofItemAtPath: disk.url(for: "s-\(index)").path)
        }
        disk.write(Self.json(ChatTailCacheTests.tail(2)), for: "s-5")
        await disk.settled()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 3)
        #expect(await disk.read("s-0") == nil)
        #expect(await disk.read("s-5") != nil)
        // Over the byte bound: never written.
        disk.write(Self.json(ChatTailCacheTests.tail(200)), for: "big")
        #expect(await disk.read("big") == nil)
        // Not a tail: read as none and removed.
        try Data("{\"events\":[]}".utf8).write(to: disk.url(for: "bad"))
        #expect(await disk.read("bad") == nil)
        #expect(!FileManager.default.fileExists(atPath: disk.url(for: "bad").path))
    }

    /// A session id never names a path.
    @Test func aSessionIdIsHashedIntoTheFileName() {
        let disk = AgentPaneTailDisk(directory: Self.folder())
        let url = disk.url(for: "../../peer/one")
        #expect(url.deletingLastPathComponent() == disk.directory)
        #expect(url.lastPathComponent.count == 64 + ".json".count)
    }
}
