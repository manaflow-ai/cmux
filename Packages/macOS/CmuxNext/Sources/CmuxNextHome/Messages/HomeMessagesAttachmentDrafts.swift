public import CmuxHomeCore
public import CmuxNextSettings
import CmuxNextCompat
public import Foundation

/// The Messages page's staged attachments across launches (`cmux.home.messages.attachments.*`),
/// in HomeStore's draft cache beside the text drafts, as the native composer kept them:
/// - the page's own: each part it uploaded, kept by its hash with its position
///   (``HomeStore/setUploadedDraftAttachment(_:hash:for:)``): a page adds or removes one part, so two
///   pages showing one conversation never overwrite each other's;
/// - the native composer's (``HomeStore/draftAttachments(for:)``, files in the blob cache): handed
///   to the page once, with their bytes, for it to upload into its tray. The page names the ones
///   it took when it saves, and only those leave HomeStore, so none is lost on the way.
///
/// The page's own parts keep their bytes too, as the native drafts kept theirs in the blob cache
/// (round 6 F1): the owner collects an upload no message names after a day, so a relaunched tray
/// needs the bytes to upload again. Each part's file is one file by its hash in ``directory`` (beside
/// the blob cache, whose prune keeps only the files HomeStore knows), written in ~1 MB chunks
/// (`attachments.write`), read back the same way (`attachments.read`), and removed with the last
/// entry that names it (``releaseBytes(_:)``). At most ``maxFileBytes`` a file and ``maxTotalBytes``
/// in all: a file past either keeps only its part, as before.
@MainActor
public struct HomeMessagesAttachmentDrafts {
    /// The largest native draft file handed to the page, and all of them together (a draft over
    /// either stays in HomeStore, where a later build can still read it).
    public static let maxFileBytes = 25_000_000
    public static let maxTotalBytes = 50_000_000

    /// The largest chunk read back at once (as the preparer's reads).
    public static let maxReadBytes = HomeAttachmentPreparer.maxReadBytes

    private let store: HomeStore
    /// Where the page's parts keep their bytes, one file per hash.
    public let directory: URL

    public init(store: HomeStore, directory: URL? = nil) {
        self.store = store
        self.directory = directory ?? Self.directory(beside: store.blobCacheDirectory)
    }

    /// `<blob cache>-drafts`, beside HomeStore's blob cache.
    public nonisolated static func directory(beside blobs: URL) -> URL {
        blobs.deletingLastPathComponent().appending(path: blobs.lastPathComponent + "-drafts", directoryHint: .isDirectory)
    }

    /// `{attachments: {id: [part]}, files: {id: {hash: at}}, legacy: {id: [{hash, name, mimeType, data}]}}`;
    /// `files` names the parts whose bytes are kept here (`at`: when the part was kept), `data` is base64.
    /// A kept file no entry names any more (its page went before it removed it) goes.
    public func load() async -> JSONValue {
        var own: [String: JSONValue] = [:]
        var files: [String: JSONValue] = [:]
        var named: Set<String> = []
        let kept = await Self.keptFiles(directory)
        for id in store.uploadedDraftAttachmentConversations {
            let entries = store.uploadedDraftAttachments(for: id).values.compactMap { try? JSONValue.parse(Data($0.utf8)) }
                .sorted { ($0.value(at: ["at"])?.doubleValue ?? 0) < ($1.value(at: ["at"])?.doubleValue ?? 0) }
            let parts = entries.compactMap { $0.value(at: ["part"]) }
            if !parts.isEmpty { own[id.rawValue] = .array(parts) }
            var times: [String: JSONValue] = [:]
            for entry in entries {
                guard let hash = entry.value(at: ["part", "hash"])?.stringValue else { continue }
                named.insert(hash)
                if kept[hash] == entry.value(at: ["part", "byteCount"])?.doubleValue.flatMap({ Int(exactly: $0) }) {
                    times[hash] = .number(entry.value(at: ["at"])?.doubleValue ?? 0)
                }
            }
            if !times.isEmpty { files[id.rawValue] = .object(times) }
        }
        named.formUnion(HomeMessagesOutbox(store: store).attachmentHashes())
        let orphans = kept.keys.filter { !named.contains($0) }
        if !orphans.isEmpty { await Self.removeFiles(orphans.map { fileURL($0) }) }
        var legacy: [String: JSONValue] = [:]
        var total = 0
        for id in store.draftAttachmentConversations {
            var files: [JSONValue] = []
            for attachment in store.draftAttachments(for: id) where attachment.ref.byteCount <= Self.maxFileBytes {
                guard total + attachment.ref.byteCount <= Self.maxTotalBytes, let data = await Self.read(attachment.fileURL) else { continue }
                total += data.count
                files.append(.object(["hash": .string(attachment.ref.hash), "name": .string(attachment.ref.name),
                                      "mimeType": .string(attachment.ref.mimeType), "data": .string(data.base64EncodedString())]))
            }
            if !files.isEmpty { legacy[id.rawValue] = .array(files) }
        }
        return .object(["attachments": .object(own), "files": .object(files), "legacy": .object(legacy)])
    }

    /// Writes one chunk of part `hash`'s bytes (`offset`: the bytes written so far; 0 starts the
    /// file again); the last chunk (`offset + data.count == byteCount`) makes it the kept file.
    /// Throws past ``maxFileBytes`` or ``maxTotalBytes`` (nothing is written), or out of order.
    public func write(hash: String, offset: Int, data: Data, byteCount: Int) async throws {
        guard Self.isHash(hash) else { throw Refusal.noHash }
        guard byteCount > 0, byteCount <= Self.maxFileBytes else { throw Refusal.tooLarge }
        guard offset >= 0, offset + data.count <= byteCount else { throw Refusal.outOfOrder }
        if offset == 0 {
            let used = await Self.keptBytes(directory, except: hash)
            guard used + byteCount <= Self.maxTotalBytes else { throw Refusal.tooLarge }
        }
        let done = offset + data.count == byteCount
        try await Self.append(data, at: offset, to: partURL(hash), finishing: done ? fileURL(hash) : nil)
    }

    /// `length` bytes of part `hash`'s kept file from `offset`; throws when it has none.
    public func read(hash: String, offset: Int, length: Int) async throws -> Data {
        guard Self.isHash(hash) else { throw Refusal.noHash }
        guard offset >= 0, length > 0, length <= Self.maxReadBytes else { throw Refusal.outOfOrder }
        return try await Self.read(fileURL(hash), offset: UInt64(offset), length: length)
    }

    /// Removes part `hash`'s kept bytes once no conversation's entry names it (``remove(_:for:)``
    /// went first) and no unsent send of the outbox does: a sent file's bytes are the outbox's
    /// until that send is delivered or discarded (``HomeMessagesOutbox``), so Retry after a
    /// relaunch can upload them again.
    public func releaseBytes(_ hash: String) async {
        guard Self.isHash(hash) else { return }
        let named = store.uploadedDraftAttachmentConversations.contains { store.uploadedDraftAttachments(for: $0)[hash] != nil }
        guard !named, !HomeMessagesOutbox(store: store).attachmentHashes().contains(hash) else { return }
        await Self.removeFiles([fileURL(hash), partURL(hash)])
    }

    /// The kept file of part `hash`.
    public func fileURL(_ hash: String) -> URL {
        directory.appending(path: hash, directoryHint: .notDirectory)
    }

    private func partURL(_ hash: String) -> URL {
        directory.appending(path: hash + ".part", directoryHint: .notDirectory)
    }

    /// A content hash (lowercase hex): it names a file here, so nothing else may.
    nonisolated static func isHash(_ hash: String) -> Bool {
        (16...128).contains(hash.utf8.count) && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Keeps one uploaded part (`at`: its place in the tray) as `id`'s, by its hash.
    public func put(_ part: JSONValue, at: Double, for id: ConversationID) throws {
        guard let hash = part.value(at: ["hash"])?.stringValue, !hash.isEmpty else { throw Refusal.noHash }
        store.setUploadedDraftAttachment(JSONValue.object(["part": part, "at": .number(at)]).compactText, hash: hash, for: id)
    }

    /// Lets go of one uploaded part (sent, or removed from the tray).
    public func remove(_ hash: String, for id: ConversationID) {
        store.setUploadedDraftAttachment(nil, hash: hash, for: id)
    }

    /// Lets go of the native drafts the page took (`migrated`: their hashes).
    public func release(_ migrated: Set<String>, for id: ConversationID) {
        guard !migrated.isEmpty else { return }
        let kept = store.draftAttachments(for: id)
        let left = kept.filter { !migrated.contains($0.ref.hash) }
        if left.count != kept.count { store.setDraftAttachments(left, for: id) }
    }

    public enum Refusal: Error {
        case noHash
        case tooLarge
        case outOfOrder
    }

    @concurrent nonisolated static func read(_ url: URL) async -> Data? {
        try? Data(blockingContentsOf: url)
    }

    /// The finished kept files by hash, with their sizes.
    @concurrent nonisolated static func keptFiles(_ directory: URL) async -> [String: Int] {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        var out: [String: Int] = [:]
        for name in names where isHash(name) {
            let size = (try? FileManager.checked.attributesOfItem(atPath: directory.appending(path: name).path)[.size]) as? NSNumber
            out[name] = size?.intValue ?? 0
        }
        return out
    }

    /// Every byte kept here (finished and partial files) but part `hash`'s own.
    @concurrent nonisolated static func keptBytes(_ directory: URL, except hash: String) async -> Int {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        var total = 0
        for name in names where name != hash && name != hash + ".part" {
            let size = (try? FileManager.checked.attributesOfItem(atPath: directory.appending(path: name).path)[.size]) as? NSNumber
            total += size?.intValue ?? 0
        }
        return total
    }

    @concurrent nonisolated static func append(_ data: Data, at offset: Int, to url: URL, finishing final: URL?) async throws {
        if offset == 0 {
            try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.checked.createFile(atPath: url.path, contents: nil) else { throw Refusal.outOfOrder }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() == UInt64(offset) else { throw Refusal.outOfOrder }
        try handle.blockingWrite(contentsOf: data)
        guard let final else { return }
        try? FileManager.checked.removeItem(at: final)
        try FileManager.checked.moveItem(at: url, to: final)
    }

    @concurrent nonisolated static func read(_ url: URL, offset: UInt64, length: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.blockingRead(upToCount: length) ?? Data()
    }

    @concurrent nonisolated static func removeFiles(_ urls: [URL]) async {
        for url in urls { try? FileManager.checked.removeItem(at: url) }
    }
}
