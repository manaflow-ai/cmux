import Foundation

/// Brings a cache the React Messages page wrote (#37736) back to the native composer's state, once,
/// as the store restores it: the page kept its unsent sends (`pendingWebSends`) and its staged
/// uploads (`uploadedDraftAttachments`) beside the native fields, and the native transcript reads
/// neither. Without this an upgrade drops failed messages and staged files, and the next index
/// write (which never writes those fields) loses them for good.
///
/// - Each pending send becomes a native send with its idempotency key, text, thread and reply
///   (``HomeCachedSend``): Retry never sends it twice. Native sends hold text only, so a send's
///   files go into its conversation's draft attachments, after the draft's own.
/// - Each staged part becomes a native draft attachment, in the page's tray order. Its kept bytes
///   (`<blob cache>-drafts/<hash>`) move into the blob cache as `<hash>/data.<ext>`, where the
///   prune keeps a draft's files.
/// - Native state wins: a send key or attachment hash the native fields already hold is not added
///   again. A part whose bytes were never kept is still recorded, so nothing is dropped on disk.
enum HomeWebCacheMigration {
    /// `snapshot` with the page's state moved into the native fields (legacy fields cleared), and
    /// whether anything moved. Moves the kept files; a move that fails leaves the file in place
    /// and the record pointing at it.
    static func migrate(_ snapshot: HomeCacheSnapshot, blobCache: URL) -> (snapshot: HomeCacheSnapshot, migrated: Bool) {
        let uploaded = snapshot.uploadedDraftAttachments ?? [:]
        let pending = snapshot.pendingWebSends ?? [:]
        guard !uploaded.isEmpty || !pending.isEmpty else { return (snapshot, false) }
        var out = snapshot
        out.uploadedDraftAttachments = nil
        out.pendingWebSends = nil
        let kept = keptDirectory(beside: blobCache)
        var attachments = out.draftAttachments ?? [:]
        var keys = Set(out.sends.map(\.key))

        func add(_ ref: AttachmentRef, to id: ConversationID) {
            var list = attachments[id] ?? []
            guard !list.contains(where: { $0.ref.hash == ref.hash }) else { return }
            list.append(draft(ref, kept: kept, blobCache: blobCache))
            attachments[id] = list
        }

        for id in uploaded.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let entries = (uploaded[id] ?? [:]).values.compactMap(object)
                .sorted { number($0["at"]) < number($1["at"]) }
            for entry in entries {
                guard let part = entry["part"] as? [String: Any], let ref = attachmentRef(part) else { continue }
                add(ref, to: id)
            }
        }

        for id in pending.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let rows = (pending[id] ?? [:]).compactMap { key, text in object(text).map { (key, $0) } }
                .sorted { number($0.1["createdAt"]) < number($1.1["createdAt"]) }
            for (entryKey, row) in rows {
                let key = IdempotencyKey((row["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entryKey)
                for part in (row["attachments"] as? [[String: Any]]) ?? [] {
                    if let ref = attachmentRef(part) { add(ref, to: id) }
                }
                let text = (row["text"] as? String) ?? ""
                guard !text.isEmpty, !keys.contains(key) else { continue }
                keys.insert(key)
                let createdAt = number(row["createdAt"])
                out.sends.append(HomeCachedSend(
                    key: key, conversation: id, parts: [.text(text)],
                    issuedAt: createdAt > 0 ? Date(timeIntervalSince1970: createdAt / 1000) : Date(),
                    failed: (row["failed"] as? Bool) ?? true,
                    threadRoot: (row["threadRoot"] as? String).map(MessageID.init(rawValue:)),
                    parent: (row["replyTo"] as? String).map(MessageID.init(rawValue:))))
            }
        }
        out.draftAttachments = attachments.isEmpty ? nil : attachments
        return (out, true)
    }

    /// Where the page kept its parts' bytes: `<blob cache>-drafts`, beside the blob cache.
    static func keptDirectory(beside blobCache: URL) -> URL {
        blobCache.deletingLastPathComponent().appendingPathComponent(blobCache.lastPathComponent + "-drafts", isDirectory: true)
    }

    /// A native draft for `ref`, its bytes moved into the blob cache. The page uploaded only the
    /// original, so the ref keeps no poster or preview this client has no file for.
    private static func draft(_ ref: AttachmentRef, kept: URL, blobCache: URL) -> HomeCachedDraftAttachment {
        var ref = ref
        ref.poster = nil
        ref.preview = nil
        let fm = FileManager.default
        let source = kept.appendingPathComponent(ref.hash)
        let destination = AttachmentMedia.blobURL(root: blobCache, hash: ref.hash,
                                                  fileExtension: (ref.name as NSString).pathExtension.lowercased())
        var fileURL = destination
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: source.path) {
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
            } catch {
                fileURL = source
            }
        }
        return HomeCachedDraftAttachment(LocalAttachment(ref: ref, fileURL: fileURL))
    }

    /// The page's attachment part (`HomeAttachment`, camelCase) as a ref; nil without a hash.
    static func attachmentRef(_ part: [String: Any]) -> AttachmentRef? {
        guard let hash = part["hash"] as? String, !hash.isEmpty,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        func int(_ key: String) -> Int? { (part[key] as? NSNumber)?.intValue }
        return AttachmentRef(hash: hash, name: (part["name"] as? String) ?? hash,
                             mimeType: (part["mimeType"] as? String) ?? "application/octet-stream",
                             byteCount: int("byteCount") ?? 0, width: int("width"), height: int("height"),
                             durationMs: int("durationMs"))
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}
