import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextWakeups
@testable import CmuxNextApp
import Foundation
import Testing

/// Any file attaches in a chat on this Mac (Lawrence 2026-10-20): what the composer can't put in
/// the prompt (a binary, a large text file) is saved owner-only and named by its path.
@Suite struct AgentChatUploadsTests {
    @Test func savesEachFileOwnerOnlyUnderItsOwnName() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "agent-chat-uploads-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "upload", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let binary = Data([0, 1, 2, 0xff])
        let files = [AgentPaneUpload(name: "state.sqlite", data: binary), AgentPaneUpload(name: "state.sqlite", data: Data("b".utf8)),
                     AgentPaneUpload(name: "index.html", data: Data("<p>x</p>".utf8))]
        let paths = try AgentChatUploads.write(files, in: folder)
        #expect(paths.count == 3)
        #expect(Set(paths).count == 3, "two files with one name keep both")
        #expect(paths.map { ($0 as NSString).lastPathComponent } == ["state.sqlite", "state.sqlite", "index.html"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == binary)
        let mode = try FileManager.default.attributesOfItem(atPath: paths[2])[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
    }

    /// Nothing ever deleted a chat's uploads. A deleted chat's go with it, and any older than the
    /// age cap goes at launch; what the app did not name, a symlink and a file stay.
    @Test func aDeletedChatsUploadsAndOldOnesGoAndNothingElse() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "agent-chat-uploads-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outside = root.appendingPathExtension("outside")
        defer {
            try? manager.removeItem(at: root)
            try? manager.removeItem(at: outside)
        }
        let now = Date()
        func upload(_ chat: String?, age days: Double) throws -> URL {
            let parent = chat.map { AgentChatUploads.chatFolder($0, in: root) } ?? root
            let folder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
            _ = try AgentChatUploads.write([AgentPaneUpload(name: "a.txt", data: Data("x".utf8))], in: folder)
            try manager.setAttributes([.creationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: folder.path)
            return folder
        }
        let old = try upload("chat-a", age: 31), new = try upload("chat-a", age: 1)
        let onlyOld = try upload("chat-b", age: 40), newChatOld = try upload(nil, age: 45), newChatNew = try upload(nil, age: 2)
        let notes = AgentChatUploads.chatFolder("chat-c", in: root).appending(path: "notes", directoryHint: .isDirectory)
        try manager.createDirectory(at: notes, withIntermediateDirectories: true)
        try manager.setAttributes([.creationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: notes.path)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appending(path: "keep.txt"))
        try manager.createSymbolicLink(at: AgentChatUploads.chatFolder("chat-d", in: root), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appending(path: UUID().uuidString.lowercased()), withDestinationURL: outside)

        #expect(AgentChatUploads.sweep(root, now: now) == 3)
        #expect(!manager.fileExists(atPath: old.path) && manager.fileExists(atPath: new.path))
        #expect(!manager.fileExists(atPath: onlyOld.deletingLastPathComponent().path), "an emptied chat folder goes")
        #expect(!manager.fileExists(atPath: newChatOld.path) && manager.fileExists(atPath: newChatNew.path))
        #expect(manager.fileExists(atPath: notes.path))
        #expect(manager.fileExists(atPath: outside.appending(path: "keep.txt").path))
        #expect(AgentChatUploads.sweep(root, now: now) == 0)

        // A deleted chat's folder goes; another chat's, a link and a name that is no session id stay.
        let uuidChat = try upload("0190a000-0000-7000-8000-000000000001", age: 1)
        AgentChatUploads.remove(session: "chat-a", in: root)
        AgentChatUploads.remove(session: "0190a000-0000-7000-8000-000000000001", in: root)
        #expect(!manager.fileExists(atPath: new.deletingLastPathComponent().path))
        #expect(!manager.fileExists(atPath: uuidChat.deletingLastPathComponent().path))
        #expect(manager.fileExists(atPath: newChatNew.path))
        AgentChatUploads.remove(session: "chat-d", in: root)
        AgentChatUploads.remove(session: "../outside", in: root)
        #expect(manager.fileExists(atPath: outside.appending(path: "keep.txt").path))
        #expect(manager.fileExists(atPath: notes.path))
    }

    @Test func aSessionIdIsOneFolderName() {
        for good in ["0190a000-0000-7000-8000-000000000001", "chat_1"] { #expect(AgentChatUploads.isSessionName(good), "\(good)") }
        for bad in ["", ".", "..", "a/b", "huge-blue/chat", "é"] { #expect(!AgentChatUploads.isSessionName(bad), "\(bad)") }
    }
}

/// Only this Mac's acpmux deleting one of its own chats deletes the chat's uploads. The watch also
/// relays a peer's or the Cloud VM's purge (a Cloud lease ending relays one per chat, under the
/// chat's own id), and Bring Back purges the closed copy it replaces under the same id: those
/// chats still exist, and their prompts name the files.
@MainActor
@Suite(.serialized)
struct AgentChatUploadsPurgeTests {
    @Test func onlyThisMacsOwnDeleteDeletesAChatsUploads() async throws {
        let acpmux = try StandInAcpmux(sessions: [])
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: AgentTurnStateStore())
        var deleted: [String] = []
        let previous = AgentTurnStateFeed.purged
        AgentTurnStateFeed.purged = { deleted.append($0) }
        defer { AgentTurnStateFeed.purged = previous }
        feed.start(localHost: "install:chat-uploads")
        func purged(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            let params: [String: Any] = ["sessionId": id, "session": ["sessionId": id], "kind": "purged", "recordKind": "purged", "seq": 1]
            return params.merging(extra) { $1 }
        }
        acpmux.push(params: purged("on-cloud", ["peer": "cloud-vm"]))
        acpmux.push(params: purged("brought-back", ["replaced": true]))
        acpmux.push(params: purged("deleted"))
        let deadline = ContinuousClock.now + .seconds(5)
        while deleted.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(deleted == ["deleted"])
        withExtendedLifetime((acpmux, feed)) {}
    }
}

/// A file streamed into a chat on this Mac (`chat.upload.begin`, `.chunk`, `.finish`, `.cancel`)
/// has no size cap, never sits whole in memory and never blocks the main thread (Leo, 2026-10-24:
/// "we shouldn't have this limit"; 2026-10-25: "arbitarrily large file sizes the composer should
/// never ever freeze and prevent new things from happening/from cancelling the thing").
@MainActor
@Suite(.serialized)
struct AgentChatUploadsStreamTests {
    private static let chunkBytes = AgentPaneUploadStageRequest.maximumChunkBytes
    private static let roomy: @Sendable (URL) -> Int64? = { _ in 1 << 40 }

    private static func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "agent-chat-stream-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func stages() -> AgentUploadStages<AgentUploadFile> {
        AgentUploadStages(owner: "test") { file in Task { await file.discard() } }
    }

    private static func value(_ reply: [String: Any]) -> [String: Any]? { reply["value"] as? [String: Any] }
    private static func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    /// A 3 GiB video starts, streams a few hundred chunks while this process's memory stays well under
    /// what was sent and the main thread stays free, and its cancel deletes the partial file.
    @Test func aMultiGigabyteUploadStreamsWithoutMemoryOrMainThreadAndItsCancelDeletesIt() async throws {
        let root = Self.root(), stages = Self.stages()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = 3 * 1024 * 1024 * 1024, chunks = 256
        let begun = await AgentChatUploads.stage(.begin(name: "movie.mov", size: size, batchToken: nil, batch: nil),
                                                 session: "chat", root: root, stages: stages, freeBytes: Self.roomy)
        let token = try #require(Self.value(begun)?["token"] as? String, "\(begun)")
        let staged = try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasPrefix("staged-") })
        let chunk = Data(repeating: 0x5A, count: Self.chunkBytes).base64EncodedString()

        let probe = MainThreadProbe()
        probe.start()
        let before = ProcessUsage.sample(getpid())?.physFootprint ?? 0
        var peak = before
        for index in 0..<chunks {
            let offset = index * Self.chunkBytes
            let wrote = await AgentChatUploads.stage(.chunk(token: token, offset: offset, base64: chunk), session: "chat", root: root, stages: stages)
            #expect(Self.value(wrote)?["offset"] as? Int == offset + Self.chunkBytes, "\(wrote)")
            peak = max(peak, ProcessUsage.sample(getpid())?.physFootprint ?? 0)
        }
        let stalls = probe.stop()
        let streamed = UInt64(chunks * Self.chunkBytes)
        let onDisk = try FileManager.default.attributesOfItem(atPath: root.appending(path: staged).appending(path: "movie.mov").path)[.size] as? UInt64
        #expect(onDisk == streamed)
        // The file goes to disk as it comes: memory grows by far less than the 128 MiB sent.
        #expect(peak - before < streamed / 2, "footprint grew \(peak - before) bytes for \(streamed) streamed")
        // Decoding and writing run off the main thread: it answers within a few ms all through.
        let sorted = stalls.sorted()
        let p99 = sorted.isEmpty ? .zero : sorted[sorted.count * 99 / 100]
        print("AGENT-UPLOAD-STREAM chunks=\(chunks) pings=\(stalls.count) main_p99=\(p99) main_max=\(sorted.last ?? .zero) footprint_growth=\(peak - before)")
        #expect(stalls.count > chunks, "the probe reached the main thread")
        #expect(p99 < .milliseconds(4), "main thread blocked \(p99) at p99")

        let cancelled = await AgentChatUploads.stage(.cancel(token: token), session: "chat", root: root, stages: stages)
        #expect(cancelled["ok"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: staged).path), "the cancelled upload's partial file stayed")
        #expect(stages.count == 0)
        let late = await AgentChatUploads.stage(.chunk(token: token, offset: Int(streamed), base64: chunk), session: "chat", root: root, stages: stages)
        #expect(Self.code(late) == "upload_failed")
    }

    /// A finished file moves to its chat's folder, owner-only, whole; nothing of its staging stays.
    @Test func aFinishedUploadIsTheWholeFileInItsChatsFolder() async throws {
        let root = Self.root(), stages = Self.stages()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<(2 * Self.chunkBytes + 3)).map { UInt8($0 % 251) })
        let begun = await AgentChatUploads.stage(.begin(name: "clip.bin", size: bytes.count, batchToken: nil, batch: nil),
                                                 session: "chat", root: root, stages: stages, freeBytes: Self.roomy)
        let token = try #require(Self.value(begun)?["token"] as? String, "\(begun)")
        for offset in stride(from: 0, to: bytes.count, by: Self.chunkBytes) {
            let piece = bytes[offset..<min(offset + Self.chunkBytes, bytes.count)].base64EncodedString()
            _ = await AgentChatUploads.stage(.chunk(token: token, offset: offset, base64: piece), session: "chat", root: root, stages: stages)
        }
        // A chunk at the wrong offset is refused and changes nothing.
        let skipped = await AgentChatUploads.stage(.chunk(token: token, offset: 0, base64: "AAAA"), session: "chat", root: root, stages: stages)
        #expect(Self.code(skipped) == "upload_failed")
        let finished = await AgentChatUploads.stage(.finish(token: token), session: "chat", root: root, stages: stages)
        let path = try #require(Self.value(finished)?["path"] as? String, "\(finished)")
        #expect(path.hasPrefix(AgentChatUploads.chatFolder("chat", in: root).path + "/") && path.hasSuffix("/0/clip.bin"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("staged-") })
    }

    /// The only bound is the disk: a file it lacks room for is refused at once, naming what is free.
    @Test func aFileTheDiskCannotHoldIsRefusedForSpace() async throws {
        let root = Self.root(), stages = Self.stages()
        defer { try? FileManager.default.removeItem(at: root) }
        let free: Int64 = 1_234_000_000
        let refused = await AgentChatUploads.stage(.begin(name: "movie.mov", size: 2 << 30, batchToken: nil, batch: nil),
                                                   session: "chat", root: root, stages: stages, freeBytes: { _ in free })
        #expect(Self.code(refused) == "no_space")
        let message = try #require((refused["error"] as? [String: Any])?["userMessage"] as? String)
        #expect(message.contains("movie.mov") && message.contains(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)), "\(message)")
        #expect(!FileManager.default.fileExists(atPath: root.path), "a refused upload made a folder")
        #expect(stages.count == 0)
    }

    /// Each upload has one expiry, which a chunk moves on; one whose page went away goes with its
    /// partial file when it expires, and no timer or task is left per chunk.
    @Test func anAbandonedUploadExpiresWithItsPartialFile() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date()
        var expired: [AgentUploadFile] = []
        let stages = AgentUploadStages<AgentUploadFile>(owner: "test", now: { now }) { expired.append($0) }
        let begun = await AgentChatUploads.stage(.begin(name: "a.bin", size: 8, batchToken: nil, batch: nil),
                                                 session: "chat", root: root, stages: stages, freeBytes: Self.roomy)
        let token = try #require(Self.value(begun)?["token"] as? String)
        now += AgentUploadStages<AgentUploadFile>.lifetime - 1
        _ = await AgentChatUploads.stage(.chunk(token: token, offset: 0, base64: "AAAA"), session: "chat", root: root, stages: stages)
        now += 2
        stages.expireDue()
        #expect(expired.isEmpty, "a chunk moves the expiry on")
        now += AgentUploadStages<AgentUploadFile>.lifetime
        stages.expireDue()
        #expect(expired.count == 1 && stages.count == 0)
        for file in expired { await file.discard() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// Pings the main thread from a background thread every millisecond and records how late each
    /// ping ran: how long the main thread was busy.
    private final class MainThreadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stalls: [Duration] = []
        private var running = true
        private var thread: Thread?

        func start() {
            let thread = Thread { [self] in
                while lock.withLock({ running }) {
                    let sent = ContinuousClock.now
                    DispatchQueue.main.async { [self] in
                        let late = sent.duration(to: .now)
                        lock.withLock { if running { stalls.append(late) } }
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            self.thread = thread
            thread.start()
        }

        func stop() -> [Duration] {
            lock.withLock {
                running = false
                return stalls
            }
        }
    }
}
