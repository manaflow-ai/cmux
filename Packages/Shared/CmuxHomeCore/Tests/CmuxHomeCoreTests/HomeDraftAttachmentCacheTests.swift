import Foundation
import Testing
import CmuxHomeCoreTestSupport
import UniformTypeIdentifiers
@testable import CmuxHomeCore

/// A compose field's pictures and files survive a relaunch with its text
/// (Leo 2026-10-21: "my screenshots didnt get saved in the draft when i
/// closed the app"). The cache kept the draft's text only, so a pasted
/// screenshot was gone after Quit while the words around it came back.
@MainActor
@Suite struct HomeDraftAttachmentCacheTests {
    static let austin = ConversationID("conv_austin")

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-attachments-\(UUID().uuidString)")
    }

    static func store(_ root: URL) -> HomeStore {
        HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("blobs"),
                  cache: HomeCache(url: root.appendingPathComponent("home.json")), cacheWriteDelay: .zero)
    }

    /// A launch that pasted two attachments under some text, then quit.
    func lastLaunch(_ root: URL) async throws -> [LocalAttachment] {
        let store = Self.store(root)
        store.start()
        await waitUntil { store.isOnline }
        let shot = try await store.prepareAttachment(data: Data("screenshot bytes".utf8), typeIdentifier: UTType.data.identifier)
        let notes = try await store.prepareAttachment(data: Data("notes".utf8), typeIdentifier: UTType.plainText.identifier)
        store.setDraft("look at these", for: Self.austin)
        store.setDraftAttachments([shot, notes], for: Self.austin)
        store.stop()
        await store.flushCache()
        return [shot, notes]
    }

    @Test func aDraftsAttachmentsComeBackAfterARelaunchInOrder() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasted = try await lastLaunch(root)
        let next = Self.store(root)
        next.start()
        defer { next.stop() }
        #expect(next.draft(for: Self.austin) == "look at these")
        #expect(next.draftAttachments(for: Self.austin) == pasted)
    }

    @Test func clearingTheAttachmentsTakesThemOutOfTheCache() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await lastLaunch(root)
        let next = Self.store(root)
        next.start()
        next.setDraftAttachments([], for: Self.austin)
        next.stop()
        await next.flushCache()
        #expect(try #require(HomeCache(url: root.appendingPathComponent("home.json")).load()).draftAttachments == nil,
                "a sent or emptied field leaves the cache")
        let third = Self.store(root)
        third.start()
        defer { third.stop() }
        #expect(third.draftAttachments(for: Self.austin).isEmpty)
    }

    @Test func anAttachmentWhoseBytesAreGoneIsSkipped() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasted = try await lastLaunch(root)
        try FileManager.default.removeItem(at: pasted[0].fileURL)
        let next = Self.store(root)
        next.start()
        defer { next.stop() }
        #expect(next.draftAttachments(for: Self.austin) == [pasted[1]])
    }

    /// A screenshot whose preview is gone cannot be sent (the upload needs it),
    /// so it is skipped like one whose bytes are gone.
    @Test func anAttachmentWhosePreviewIsGoneIsSkipped() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Self.store(root)
        store.start()
        await waitUntil { store.isOnline }
        var shot = try await store.prepareAttachment(data: Data("screenshot bytes".utf8), typeIdentifier: UTType.data.identifier)
        let preview = shot.fileURL.deletingLastPathComponent().appendingPathComponent("preview")
        try Data("preview bytes".utf8).write(to: preview)
        shot.previewURL = preview
        let notes = try await store.prepareAttachment(data: Data("notes".utf8), typeIdentifier: UTType.plainText.identifier)
        store.setDraftAttachments([shot, notes], for: Self.austin)
        store.stop()
        await store.flushCache()
        try FileManager.default.removeItem(at: preview)
        let next = Self.store(root)
        next.start()
        defer { next.stop() }
        #expect(next.draftAttachments(for: Self.austin) == [notes])
    }

    /// The blob cache prunes what nothing holds; a draft's files are held.
    @Test func thePruneKeepsADraftsFiles() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasted = try await lastLaunch(root)
        let next = Self.store(root)
        next.start()
        defer { next.stop() }
        await next.pruneBlobCache(now: Date().addingTimeInterval(HomeStore.blobCacheMaxAge * 10))
        #expect(pasted.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        #expect(next.draftAttachments(for: Self.austin) == pasted)
    }

    /// The Messages page's staged attachments (already uploaded: each part's JSON by its hash)
    /// survive a relaunch beside the text; removing one leaves the others, and removing the last
    /// takes the conversation out (review of cmux#37736, round 3 F3 and round 5 F1).
    @Test func aWebComposersUploadedAttachmentsComeBackAfterARelaunch() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = #"{"at":1,"part":{"type":"attachment","hash":"h1","name":"notes.txt","mimeType":"text/plain","byteCount":5}}"#
        let second = #"{"at":2,"part":{"type":"attachment","hash":"h2","name":"plan.txt","mimeType":"text/plain","byteCount":4}}"#
        let store = Self.store(root)
        store.start()
        store.setUploadedDraftAttachment(first, hash: "h1", for: Self.austin)
        store.setUploadedDraftAttachment(second, hash: "h2", for: Self.austin)
        store.stop()
        await store.flushCache()
        let next = Self.store(root)
        next.start()
        #expect(next.uploadedDraftAttachments(for: Self.austin) == ["h1": first, "h2": second])
        #expect(next.uploadedDraftAttachmentConversations == [Self.austin])
        next.setUploadedDraftAttachment(nil, hash: "h1", for: Self.austin)
        #expect(next.uploadedDraftAttachments(for: Self.austin) == ["h2": second])
        next.setUploadedDraftAttachment(nil, hash: "h2", for: Self.austin)
        next.stop()
        await next.flushCache()
        #expect(try #require(HomeCache(url: root.appendingPathComponent("home.json")).load()).uploadedDraftAttachments == nil)
    }

    /// The Messages page's unsent sends (each pending row's JSON by its key) survive a relaunch;
    /// one page removing its delivered send never drops another page's failed one (review of
    /// cmux#37736, round 4 F2 and round 5 F1).
    @Test func aWebComposersUnsentSendsComeBackAfterARelaunch() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = #"{"conversation":"austin","createdAt":1,"failed":true,"key":"k1","text":"hi"}"#
        let sent = #"{"conversation":"austin","createdAt":2,"failed":false,"key":"k2","text":"there"}"#
        let store = Self.store(root)
        store.start()
        store.setPendingWebSend(failed, key: "k1", for: Self.austin)
        store.setPendingWebSend(sent, key: "k2", for: Self.austin)
        store.setPendingWebSend(nil, key: "k2", for: Self.austin)
        store.stop()
        await store.flushCache()
        let next = Self.store(root)
        next.start()
        #expect(next.pendingWebSends(for: Self.austin) == ["k1": failed])
        #expect(next.pendingWebSendConversations == [Self.austin])
        next.setPendingWebSend(nil, key: "k1", for: Self.austin)
        next.stop()
        await next.flushCache()
        #expect(try #require(HomeCache(url: root.appendingPathComponent("home.json")).load()).pendingWebSends == nil)
    }

    /// A cache written before drafts kept attachments still decodes, with its text draft.
    @Test func aCacheWithoutDraftAttachmentsStillLoads() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = HomeCacheSnapshot()
        snapshot.drafts = [Self.austin: "older"]
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json["draftAttachments"] = nil
        let cache = HomeCache(url: root.appendingPathComponent("home.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: cache.url)
        #expect(try #require(cache.load()).drafts[Self.austin] == "older")
    }
}
