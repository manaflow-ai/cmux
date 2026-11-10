import CmuxHomeCore
import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Round 6 F1 of cmux#37736: a staged file the Messages page keeps across launches keeps its bytes,
/// as the native composer's draft attachments kept theirs in the blob cache, so a relaunched tray can
/// upload it again after the owner collected the upload; the bytes go with the last entry naming them.
@MainActor @Suite(.serialized)
struct HomeMessagesR6AttachmentsTests {
    static let hash = String(repeating: "ab", count: 32)

    static func part(_ hash: String, byteCount: Int) -> JSONValue {
        .object(["type": .string("attachment"), "hash": .string(hash), "name": .string("notes.txt"),
                 "mimeType": .string("text/plain"), "byteCount": .number(Double(byteCount))])
    }

    @Test func aKeptPartsBytesSurviveAndGoWithItsEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-messages-r6-attachments-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appending(path: "blobs"))
        store.start()
        defer { store.stop() }
        let id = HomeChiefRosterTests.ada
        let other = HomeChiefRosterTests.local
        let kept = HomeMessagesKept(store: store, keepLocation: { false })
        let bytes = Data("hello, kept file".utf8)
        let first = bytes.prefix(6), rest = bytes.dropFirst(6)

        _ = try await kept.call("attachments.put", ["conversation": .string(id.rawValue),
                                                    "part": Self.part(Self.hash, byteCount: bytes.count), "at": .number(7)])
        _ = try await kept.call("attachments.write", ["hash": .string(Self.hash), "offset": .number(0),
                                                      "byteCount": .number(Double(bytes.count)),
                                                      "data": .string(Data(first).base64EncodedString())])
        // A chunk out of order writes nothing.
        await #expect(throws: PageError.self) {
            _ = try await kept.call("attachments.write", ["hash": .string(Self.hash), "offset": .number(2),
                                                          "byteCount": .number(Double(bytes.count)),
                                                          "data": .string(Data(rest).base64EncodedString())])
        }
        _ = try await kept.call("attachments.write", ["hash": .string(Self.hash), "offset": .number(Double(first.count)),
                                                      "byteCount": .number(Double(bytes.count)),
                                                      "data": .string(Data(rest).base64EncodedString())])

        // A relaunch: the part comes back with its bytes kept, and they read back whole.
        let loaded = try #require(try await kept.call("attachments.load", [:]))
        #expect(loaded.value(at: ["files", id.rawValue, Self.hash]) == .number(7))
        let read = try #require(try await kept.call("attachments.read", ["hash": .string(Self.hash), "offset": .number(0),
                                                                         "length": .number(Double(bytes.count))]))
        #expect(read.value(at: ["data"])?.stringValue.flatMap { Data(base64Encoded: $0) } == bytes)

        // Another conversation names the same bytes: removing the first entry keeps them.
        _ = try await kept.call("attachments.put", ["conversation": .string(other.rawValue),
                                                    "part": Self.part(Self.hash, byteCount: bytes.count), "at": .number(8)])
        _ = try await kept.call("attachments.remove", ["conversation": .string(id.rawValue), "hash": .string(Self.hash)])
        let file = HomeMessagesAttachmentDrafts(store: store).fileURL(Self.hash)
        #expect(FileManager.default.fileExists(atPath: file.path))
        _ = try await kept.call("attachments.remove", ["conversation": .string(other.rawValue), "hash": .string(Self.hash)])
        #expect(!FileManager.default.fileExists(atPath: file.path), "the bytes go with the last entry that names them")
        await #expect(throws: PageError.self) {
            _ = try await kept.call("attachments.read", ["hash": .string(Self.hash), "offset": .number(0), "length": .number(4)])
        }
    }

    /// Send path: a native composer draft of any size reaches the page: the load names it with its
    /// size (no bytes inline), and its bytes read back in chunks by its hash.
    @Test func aNativeDraftOfAnySizeIsHandedOverByItsHash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-messages-r6-native-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appending(path: "blobs"))
        store.start()
        defer { store.stop() }
        let id = HomeChiefRosterTests.ada
        let bytes = Data(repeating: 7, count: 26_000_000)
        let native = try await store.prepareAttachment(data: bytes, typeIdentifier: "public.plain-text")
        store.setDraftAttachments([native], for: id)
        let kept = HomeMessagesKept(store: store, keepLocation: { false })

        let loaded = try #require(try await kept.call("attachments.load", [:]))
        let legacy = try #require(loaded.value(at: ["legacy", id.rawValue])?.arrayValue?.first)
        #expect(legacy.value(at: ["hash"])?.stringValue == native.ref.hash)
        #expect(legacy.value(at: ["byteCount"])?.doubleValue == Double(bytes.count))
        #expect(legacy.value(at: ["data"]) == nil)
        let chunk = 3 * 1024 * 1024
        let last = try #require(try await kept.call("attachments.read", ["hash": .string(native.ref.hash),
                                                                         "offset": .number(Double(bytes.count - chunk)),
                                                                         "length": .number(Double(chunk))]))
        #expect(last.value(at: ["data"])?.stringValue.flatMap { Data(base64Encoded: $0) } == bytes.suffix(chunk))
    }

    @Test func aFileOfAnySizeIsKeptAndOrphansGo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-messages-r6-bound-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appending(path: "blobs"))
        store.start()
        defer { store.stop() }
        let drafts = HomeMessagesAttachmentDrafts(store: store)
        // Send path: a staged file over 25 MB, and kept bytes past 50 MB in all, are kept too.
        let big = String(repeating: "cd", count: 32)
        try await drafts.write(hash: big, offset: 0, data: Data([1]), byteCount: 60_000_000)
        try await drafts.write(hash: Self.hash, offset: 0, data: Data([1]), byteCount: 30_000_000)
        await #expect(throws: HomeMessagesAttachmentDrafts.Refusal.noHash) {
            try await drafts.write(hash: "../escape", offset: 0, data: Data([1]), byteCount: 1)
        }
        await drafts.releaseBytes(big)
        // Bytes no entry names (their page went before it put the part) go at the next load.
        try await drafts.write(hash: Self.hash, offset: 0, data: Data([1, 2]), byteCount: 2)
        #expect(FileManager.default.fileExists(atPath: drafts.fileURL(Self.hash).path))
        _ = await drafts.load()
        #expect(!FileManager.default.fileExists(atPath: drafts.fileURL(Self.hash).path))
    }
}
