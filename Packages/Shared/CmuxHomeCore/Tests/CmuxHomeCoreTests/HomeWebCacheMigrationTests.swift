import Foundation
import Testing
import UniformTypeIdentifiers
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// A cache the React Messages page wrote (#37736) keeps its unsent sends and staged uploads in
/// `pendingWebSends` and `uploadedDraftAttachments`. The native transcript (#40611) reads neither,
/// so without a migration an upgrade dropped failed messages and staged files, and the next index
/// write deleted them for good (Codex review of #40611, F1).
@MainActor
@Suite struct HomeWebCacheMigrationTests {
    static let austin = ConversationID("conv_austin")
    static let shot = String(repeating: "a", count: 64)
    static let gone = String(repeating: "b", count: 64)
    static let sent = String(repeating: "c", count: 64)

    static func store(_ root: URL) -> HomeStore {
        HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("blobs"),
                  cache: HomeCache(url: root.appendingPathComponent("home.json")), cacheWriteDelay: .zero)
    }

    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The React build's cache: a native failed send and text draft, plus the page's two fields
    /// (two staged parts, one whose bytes were never kept; a failed reply in a thread; a send of a
    /// file alone, in a thread, with a preview), with the page's kept bytes in `blobs-drafts/<hash>`.
    func writeReactCache(_ root: URL) throws {
        let kept = root.appendingPathComponent("blobs-drafts")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("screenshot bytes".utf8).write(to: kept.appendingPathComponent(Self.shot))
        try Data("sent file".utf8).write(to: kept.appendingPathComponent(Self.sent))
        var snapshot = HomeCacheSnapshot()
        snapshot.drafts = [Self.austin: "look at these"]
        snapshot.sends = [HomeCachedSend(key: IdempotencyKey("native-1"), conversation: Self.austin, text: "native",
                                         issuedAt: Date(timeIntervalSince1970: 1_700_000_000), failed: true)]
        snapshot.uploadedDraftAttachments = [Self.austin: [
            Self.shot: try Self.json(["part": ["type": "attachment", "hash": Self.shot, "name": "shot.png", "mimeType": "image/png",
                                               "byteCount": 16, "width": 10, "height": 20,
                                               "preview": ["hash": Self.gone, "mimeType": "image/jpeg", "byteCount": 3]],
                                      "at": 2]),
            Self.gone: try Self.json(["part": ["type": "attachment", "hash": Self.gone, "name": "notes.txt", "mimeType": "text/plain",
                                               "byteCount": 5],
                                      "at": 1]),
        ]]
        snapshot.pendingWebSends = [Self.austin: [
            "k1": try Self.json(["key": "k1", "conversation": Self.austin.rawValue, "text": "failed reply",
                                 "createdAt": 1_700_000_100_000, "failed": true, "threadRoot": "msg_root", "replyTo": "msg_parent"]),
            "k2": try Self.json(["key": "k2", "conversation": Self.austin.rawValue, "text": "",
                                 "attachments": [["type": "attachment", "hash": Self.sent, "name": "log.txt",
                                                  "mimeType": "text/plain", "byteCount": 9,
                                                  "preview": ["hash": Self.gone, "mimeType": "image/jpeg", "byteCount": 3]]],
                                 "createdAt": 1_700_000_200_000, "failed": true,
                                 "threadRoot": "msg_root", "replyTo": "msg_parent"]),
        ]]
        let data = try JSONEncoder().encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"pendingWebSends\"") && text.contains("\"uploadedDraftAttachments\""))
        try data.write(to: root.appendingPathComponent("home.json"))
    }

    @Test func aReactCachesSendsAndStagedFilesBecomeNativeAndSurviveTheNextWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-web-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReactCache(root)

        let store = Self.store(root)
        store.primeFromCache()
        // Sends: the native one and the page's two, each with its idempotency key, thread and reply.
        let keys = store.log.entries.map(\.intent.key.rawValue)
        #expect(keys == ["native-1", "k1", "k2"])
        let reply = try #require(store.log.entries.first { $0.intent.key.rawValue == "k1" })
        guard case .sendMessage(let id, let parts, let threadRoot, let parent) = reply.intent.op else {
            Issue.record("k1 is not a send")
            return
        }
        #expect(id == Self.austin && parts == [.text("failed reply")])
        #expect(threadRoot == MessageID("msg_root") && parent == MessageID("msg_parent"))
        #expect(reply.intent.issuedAt == Date(timeIntervalSince1970: 1_700_000_100))
        if case .failed = reply.state {} else { Issue.record("k1 comes back as not sent") }
        // The file-only send keeps its file as a part of the same message, so Retry resends it,
        // not a different one, and none of it lands in the composer. Its upload job comes back.
        let fileOnly = try #require(store.log.entries.first { $0.intent.key.rawValue == "k2" })
        guard case .sendMessage(_, let fileParts, let fileThread, let fileParent) = fileOnly.intent.op else {
            Issue.record("k2 is not a send")
            return
        }
        #expect(fileParts.count == 1)
        guard case .attachment(let file) = fileParts.first else {
            Issue.record("k2 lost its file")
            return
        }
        #expect(file.hash == Self.sent && file.name == "log.txt" && file.preview == nil, "the page kept no preview bytes")
        #expect(store.uploads[IdempotencyKey("k2")]?.attachments.map(\.ref.hash) == [Self.sent])
        #expect(store.uploads[IdempotencyKey("k2")]?.reachedOwner == true)
        #expect(fileThread == MessageID("msg_root") && fileParent == MessageID("msg_parent"))
        if case .failed = fileOnly.state {} else { Issue.record("k2 comes back as not sent") }
        #expect(fileOnly.mayHaveBeenDelivered, "Retry resends it under the same key")
        #expect(FileManager.default.fileExists(atPath: AttachmentMedia.blobURL(
            root: store.blobCacheDirectory, hash: Self.sent, fileExtension: "txt").path), "the send's bytes are in the blob cache")
        // Drafts: the text, then the page's parts in tray order.
        #expect(store.draft(for: Self.austin) == "look at these")
        #expect(store.viewCache.draftAttachments[Self.austin]?.map(\.ref.hash) == [Self.gone, Self.shot],
                "every record is kept, the one without bytes too")
        let shown = store.draftAttachments(for: Self.austin)
        #expect(shown.map(\.ref.hash) == [Self.shot], "the ones with bytes show in the tray")
        #expect(shown.first?.ref.preview == nil, "no preview file came over")
        #expect(shown.first?.ref.width == 10 && shown.first?.ref.mimeType == "image/png")
        for attachment in shown {
            #expect(attachment.fileURL.path.hasPrefix(store.blobCacheDirectory.path), "bytes move into the blob cache")
            #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
        }
        #expect(try Data(contentsOf: shown[0].fileURL) == Data("screenshot bytes".utf8))

        // The next write keeps all of it in the native fields and none in the page's.
        await store.flushCache()
        let written = try #require(HomeCache(url: root.appendingPathComponent("home.json")).load())
        #expect(written.pendingWebSends == nil && written.uploadedDraftAttachments == nil)
        #expect(written.sends.map(\.key.rawValue).sorted() == ["k1", "k2", "native-1"])
        #expect(written.sends.first { $0.key.rawValue == "k2" }?.parts == fileParts, "the file-only send keeps its parts")
        #expect(written.draftAttachments?[Self.austin]?.map(\.ref.hash) == [Self.gone, Self.shot])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs-drafts").path),
                "the kept folder goes once every file has its copy")
        store.stop()

        // A relaunch reads the native state back, once.
        let next = Self.store(root)
        next.primeFromCache()
        defer { next.stop() }
        #expect(next.log.entries.map(\.intent.key.rawValue) == ["native-1", "k1", "k2"])
        #expect(next.draftAttachments(for: Self.austin) == shown)
    }

    @Test func aCacheWithoutThePagesFieldsIsLeftAsItIs() {
        var snapshot = HomeCacheSnapshot()
        snapshot.drafts = [Self.austin: "hi"]
        let (out, migrated) = HomeWebCacheMigration.migrate(snapshot, blobCache: URL(fileURLWithPath: "/nonexistent/blobs"))
        #expect(!migrated && out == snapshot)
    }

    /// A send of text and a file keeps both parts in order (Codex review of #40611 at 84e6fc9, F1).
    @Test func aSendWithTextAndAFileKeepsBothParts() throws {
        var snapshot = HomeCacheSnapshot()
        snapshot.pendingWebSends = [Self.austin: [
            "k3": try Self.json(["key": "k3", "text": "see attached",
                                 "attachments": [["hash": Self.sent, "name": "log.txt", "mimeType": "text/plain", "byteCount": 9]],
                                 "createdAt": 1_700_000_300_000, "failed": false]),
        ]]
        let (out, migrated) = HomeWebCacheMigration.migrate(snapshot, blobCache: URL(fileURLWithPath: "/nonexistent/blobs"))
        #expect(migrated && out.draftAttachments == nil, "nothing goes into the composer")
        let send = try #require(out.sends.first)
        #expect(send.key == IdempotencyKey("k3") && send.failed, "a send with files comes back as maybe delivered")
        #expect(send.parts == [.text("see attached"),
                               .attachment(AttachmentRef(hash: Self.sent, name: "log.txt", mimeType: "text/plain", byteCount: 9))])
    }

    /// The same bytes staged as `photo.jpg` in one conversation and `photo.jpeg` in another each get
    /// a file (Codex review of #40611 at 84e6fc9, F2): the first copy no longer consumes the source.
    @Test func theSameBytesUnderTwoNamesBothKeepAFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-web-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = root.appendingPathComponent("blobs")
        let kept = HomeWebCacheMigration.keptDirectory(beside: blobs)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("photo bytes".utf8).write(to: kept.appendingPathComponent(Self.shot))
        let other = ConversationID("conv_other")
        var snapshot = HomeCacheSnapshot()
        snapshot.uploadedDraftAttachments = [
            Self.austin: [Self.shot: try Self.json(["part": ["hash": Self.shot, "name": "photo.jpg", "mimeType": "image/jpeg",
                                                             "byteCount": 11], "at": 1])],
            other: [Self.shot: try Self.json(["part": ["hash": Self.shot, "name": "photo.jpeg", "mimeType": "image/jpeg",
                                                       "byteCount": 11], "at": 1])],
        ]
        let (out, _) = HomeWebCacheMigration.migrate(snapshot, blobCache: blobs)
        for id in [Self.austin, other] {
            let url = try #require(out.draftAttachments?[id]?.first?.fileURL)
            #expect(url.path.hasPrefix(blobs.path))
            #expect(try Data(contentsOf: url) == Data("photo bytes".utf8), "\(id.rawValue) has its bytes")
        }
        #expect(!FileManager.default.fileExists(atPath: kept.path), "the kept file goes after both copies")
    }

    /// A send with a file is cached in every state its upload job is in (uploading, sent and
    /// unanswered, failed), with the job's files, as Not Delivered (Codex review of #40611 at
    /// d35406d, F1). Without a job it is kept only when it may have reached the owner.
    @Test func aSendWithAFileIsCachedWithItsJobInEveryState() {
        let ref = AttachmentRef(hash: Self.sent, name: "log.txt", mimeType: "text/plain", byteCount: 9)
        let op = HomeOp.sendMessage(conversation: Self.austin, parts: [.text("hi"), .attachment(ref)], threadRoot: nil, parent: nil)
        let file = LocalAttachment(ref: ref, fileURL: URL(fileURLWithPath: "/tmp/blobs/\(Self.sent)/data.txt"))
        let job = HomeStore.UploadJob(conversation: Self.austin, attachments: [file])
        for state in [PendingIntent.State.sending, .unconfirmed, .failed(.ownerUnreachable)] {
            var entry = PendingIntent(intent: HomeIntent(key: IdempotencyKey("s"), op: op), state: state)
            entry.isUploading = state == .sending
            let cached = HomeCachedSend(entry, upload: job)
            #expect(cached?.parts == [.text("hi"), .attachment(ref)])
            #expect(cached?.files == [HomeCachedDraftAttachment(file)] && cached?.reachedOwner == false && cached?.failed == true)
        }
        var delivered = PendingIntent(intent: HomeIntent(key: IdempotencyKey("d"), op: op), state: .failed(.indeterminate))
        delivered.mayHaveBeenDelivered = true
        #expect(HomeCachedSend(delivered)?.parts == [.text("hi"), .attachment(ref)])
        let lost = PendingIntent(intent: HomeIntent(key: IdempotencyKey("u"), op: op), state: .failed(.ownerUnreachable))
        #expect(HomeCachedSend(lost) == nil, "no files and never sent: nothing to resend")
    }

    /// Quitting while a send with a file waits for its answer keeps the whole message: the next
    /// launch shows it Not Delivered with its upload job, and Retry delivers it once (F1).
    @Test func aSendWithAFileWaitingForItsAnswerSurvivesAQuit() async throws {
        let root = try temporaryDirectory()
        let clock = ManualClock()
        let source = MockHomeSource(options: .immediate)
        let cacheURL = root.appendingPathComponent("home.json")
        let store = HomeStore(source: source, blobCacheDirectory: root.appendingPathComponent("blobs"), clock: clock,
                              cache: HomeCache(url: cacheURL), cacheWriteDelay: .zero)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(Self.austin)
        let a = try await store.prepareAttachment(data: Data("quit while sending".utf8), typeIdentifier: UTType.plainText.identifier)
        let key = IdempotencyKey("quit-pending")
        await source.failNextSubmits(of: key, times: 1_000)
        _ = try? await store.send(conversation: Self.austin, text: "with a file", attachments: [a], key: key)
        await store.flushCache()
        store.stop()

        let written = try #require(HomeCache(url: cacheURL).load())
        let cached = try #require(written.sends.first { $0.key == key })
        #expect(cached.parts.contains(.text("with a file")) && cached.files?.map(\.ref.hash) == [a.ref.hash])

        await source.failNextSubmits(of: key, times: 0)
        let next = HomeStore(source: source, blobCacheDirectory: root.appendingPathComponent("blobs"),
                             cache: HomeCache(url: cacheURL), cacheWriteDelay: .zero)
        next.primeFromCache()
        defer { next.stop() }
        let restored = try #require(next.log.entries.first { $0.intent.key == key })
        if case .failed = restored.state {} else { Issue.record("it comes back Not Delivered") }
        #expect(next.uploads[key]?.attachments.map(\.ref.hash) == [a.ref.hash])
        next.start()
        await waitUntil { next.isOnline && !next.rows.isEmpty }
        await next.open(Self.austin)
        _ = try? await next.retry(key)
        await waitUntil { next.log.isEmpty }
        #expect(next.log.isEmpty, "Retry delivered it")
    }

    /// A migrated send whose uploads the owner swept: Retry under its key gets
    /// `unknown_attachment`, uploads the copied bytes again and delivers it once (F2).
    @Test func aMigratedSendWithAFileUploadsAgainAfterTheOwnerSweptIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-web-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = root.appendingPathComponent("blobs")
        let kept = HomeWebCacheMigration.keptDirectory(beside: blobs)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let bytes = Data("swept file".utf8)
        let hash = sha256Hex(bytes)
        try bytes.write(to: kept.appendingPathComponent(hash))
        var snapshot = HomeCacheSnapshot()
        snapshot.pendingWebSends = [Self.austin: [
            "k4": try Self.json(["key": "k4", "text": "",
                                 "attachments": [["hash": hash, "name": "swept.txt", "mimeType": "text/plain",
                                                  "byteCount": bytes.count]],
                                 "createdAt": 1_700_000_400_000, "failed": true]),
        ]]
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("home.json"))

        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: blobs,
                              cache: HomeCache(url: root.appendingPathComponent("home.json")), cacheWriteDelay: .zero)
        defer { store.stop() }
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(Self.austin)
        let before = await source.hasBlob(hash)
        #expect(!before, "the owner swept the page's upload")
        let key = IdempotencyKey("k4")
        _ = try? await store.retry(key)
        await waitUntil { store.log.isEmpty }
        let after = await source.hasBlob(hash)
        #expect(after, "the copied bytes went up again")
        let messages = try await source.snapshot(of: Self.austin, tail: 50).messages.filter { message in
            message.parts.contains { if case .attachment(let ref) = $0 { ref.hash == hash } else { false } }
        }
        #expect(messages.count == 1)
    }
}
