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

    private static func withDisk(_ given: AgentPaneTailDisk? = nil, _ body: (AgentPaneTailDisk) async throws -> Void) async rethrows {
        let cache = AgentPaneTailCache.shared
        cache.clear()
        cache.resume()
        let disk = given ?? AgentPaneTailDisk(directory: folder())
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

    private static func answersNothing(_ session: String) async -> Bool {
        await get(session) is NSNull
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

    /// #36492 review F1: after a relaunch memory is empty, and a sidebar hover's read ahead
    /// (`ifNewer`) that ends on an older record than the tail an earlier launch saved must not
    /// replace it, or the next open draws stale rows. A newer one still wins.
    @Test func anOlderHoverHandOverKeepsTheNewerDiskTail() async {
        await Self.withDisk { disk in
            disk.write(Self.json(ChatTailCacheTests.tail(5)), for: "s-1")
            await disk.settled()
            _ = ChatTailCacheTests.bridge("chat.tail", ["sessionId": "s-1", "tail": ChatTailCacheTests.tail(3), "ifNewer": true])
            await AgentPaneTailCache.shared.settled()
            #expect(ChatTailCacheTests.seqs((await disk.read("s-1"))?.foundationObject) == [1, 2, 3, 4, 5],
                    "an older read ahead replaced the newer tail on disk")
            #expect(ChatTailCacheTests.seqs(await Self.get("s-1")) == [1, 2, 3, 4, 5],
                    "an older read ahead was answered over the newer tail on disk")
            _ = ChatTailCacheTests.bridge("chat.tail", ["sessionId": "s-1", "tail": ChatTailCacheTests.tail(7), "ifNewer": true])
            await AgentPaneTailCache.shared.settled()
            #expect(ChatTailCacheTests.seqs(await Self.get("s-1")) == Array(1...7))
            #expect(ChatTailCacheTests.seqs((await disk.read("s-1"))?.foundationObject) == Array(1...7))
        }
    }

    /// The same with no memory tier read at all: the disk's own copy is what the comparison sees.
    @Test func aNewerHoverHandOverReplacesAnOlderDiskTail() async {
        await Self.withDisk { disk in
            disk.write(Self.json(ChatTailCacheTests.tail(2)), for: "s-1")
            await disk.settled()
            _ = ChatTailCacheTests.bridge("chat.tail", ["sessionId": "s-1", "tail": ChatTailCacheTests.tail(4), "ifNewer": true])
            await AgentPaneTailCache.shared.settled()
            #expect(ChatTailCacheTests.seqs(await Self.get("s-1")) == [1, 2, 3, 4])
            #expect(ChatTailCacheTests.seqs((await disk.read("s-1"))?.foundationObject) == [1, 2, 3, 4])
        }
    }

    /// #36492 review F2: a page that forgets (or hands over a tail the host refuses) while a
    /// `chat.tail.get` reads the disk tier must not have the old disk copy put back in memory and
    /// answered: the page no longer stands behind that transcript.
    @Test(arguments: [false, true]) func aForgetDuringADiskReadIsNotUndone(refused: Bool) async {
        let gate = DispatchSemaphore(value: 0)
        let (queued, readQueued) = AsyncStream<Void>.makeStream()
        let disk = AgentPaneTailDisk(directory: Self.folder(), readQueued: { readQueued.yield() })
        await Self.withDisk(disk) { disk in
            disk.write(Self.json(ChatTailCacheTests.tail(5)), for: "s-1")
            await disk.settled()
            // Hold the disk queue so the read is queued ahead of the forget's removal.
            disk.afterQueued { gate.wait() }
            async let answeredNothing = Self.answersNothing("s-1")
            for await _ in queued { break }
            let forget: [String: Any] = refused
                ? ["sessionId": "s-1", "tail": ["events": [] as [Any]]]
                : ["sessionId": "s-1"]
            _ = ChatTailCacheTests.bridge("chat.tail", forget)
            gate.signal()
            #expect(await answeredNothing, "a forgotten tail was answered from the disk read under way")
            #expect(AgentPaneTailCache.shared.tail(for: "s-1") == nil, "a forgotten tail was put back in memory")
            #expect(await disk.read("s-1") == nil)
        }
    }

    /// #36492 review F3: the quit awaits the app's state files (`AppServices.stateFilesDrained`), and
    /// that includes the chat tails' disk queue, so a quit during a save backlog still relaunches with
    /// the tail; until it ends, the quit deadline's record names the folder as still saving.
    @Test func theQuitDrainAwaitsTheTailSaves() async throws {
        let parent = Self.folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let gate = DispatchSemaphore(value: 0)
        let files = AgentPaneStateFiles(drainBegan: { gate.signal() })
        let disk = files.tails(in: parent.appending(path: "agent-chat-tails"))
        #expect(files.tails(in: parent.appending(path: "agent-chat-tails")) === disk, "two writers for one folder")
        disk.afterQueued { gate.wait() }
        disk.write(Self.json(ChatTailCacheTests.tail(3)), for: "s-1")
        #expect(files.savingFileNames().contains("agent-chat-tails"), "the quit deadline would not name the tails still saving")
        await files.drained()
        #expect(FileManager.default.fileExists(atPath: disk.url(for: "s-1").path), "the quit drain ended before the tail was saved")
        #expect(!files.savingFileNames().contains("agent-chat-tails"))
    }

    /// A session id never names a path.
    @Test func aSessionIdIsHashedIntoTheFileName() {
        let disk = AgentPaneTailDisk(directory: Self.folder())
        let url = disk.url(for: "../../peer/one")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == disk.directory.standardizedFileURL.path)
        #expect(url.lastPathComponent.count == 64 + ".json".count)
    }
}
