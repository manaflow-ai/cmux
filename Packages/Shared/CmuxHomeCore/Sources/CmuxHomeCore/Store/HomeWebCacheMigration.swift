import Foundation

/// Brings a cache the React Messages page wrote (#37736) back to the native composer's state, once,
/// as the store restores it: the page kept its unsent sends (`pendingWebSends`) and its staged
/// uploads (`uploadedDraftAttachments`) beside the native fields, and the native transcript reads
/// neither. Without this an upgrade drops failed messages and staged files, and the next index
/// write (which never writes those fields) loses them for good.
///
/// - Each pending send becomes a native send with its idempotency key, every part it had (text,
///   then its files, previews included), thread and reply (``HomeCachedSend``), as a send that may
///   have been delivered: Retry sends the same message under the same key, never a different one,
///   and a send of a file alone keeps its row too. Its files' bytes go into the blob cache.
/// - Each staged part becomes a native draft attachment, in the page's tray order. Its kept bytes
///   (`<blob cache>-drafts/<hash>`) are copied into the blob cache as `<hash>/data.<ext>`, where the
///   prune keeps a draft's files. The same bytes under two names (`photo.jpg`, `photo.jpeg`) get a
///   file each; a kept file is removed only after every record that needs it has its copy.
/// - Native state wins: a send key or attachment hash the native fields already hold is not added
///   again. A part whose bytes were never kept is still recorded, so nothing is dropped on disk.
enum HomeWebCacheMigration {
    /// `snapshot` with the page's state moved into the native fields (legacy fields cleared), and
    /// whether anything moved. Copies the kept files; a copy that fails leaves the file in place
    /// and the record pointing at it.
    static func migrate(_ snapshot: HomeCacheSnapshot, blobCache: URL) -> (snapshot: HomeCacheSnapshot, migrated: Bool) {
        let uploaded = snapshot.uploadedDraftAttachments ?? [:]
        let pending = snapshot.pendingWebSends ?? [:]
        guard !uploaded.isEmpty || !pending.isEmpty else { return (snapshot, false) }
        var out = snapshot
        out.uploadedDraftAttachments = nil
        out.pendingWebSends = nil
        var files = KeptFiles(kept: keptDirectory(beside: blobCache), blobCache: blobCache)
        var attachments = out.draftAttachments ?? [:]
        var keys = Set(out.sends.map(\.key))

        for id in uploaded.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let entries = (uploaded[id] ?? [:]).values.compactMap(object)
                .sorted { number($0["at"]) < number($1["at"]) }
            for entry in entries {
                guard let part = entry["part"] as? [String: Any], var ref = attachmentRef(part) else { continue }
                var list = attachments[id] ?? []
                guard !list.contains(where: { $0.ref.hash == ref.hash }) else { continue }
                // The page uploaded only the original, so the draft keeps no poster or preview
                // this client has no file for.
                ref.poster = nil
                ref.preview = nil
                list.append(HomeCachedDraftAttachment(LocalAttachment(ref: ref, fileURL: files.place(ref))))
                attachments[id] = list
            }
        }

        for id in pending.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let rows = (pending[id] ?? [:]).compactMap { key, text in object(text).map { (key, $0) } }
                .sorted { number($0.1["createdAt"]) < number($1.1["createdAt"]) }
            for (entryKey, row) in rows {
                let key = IdempotencyKey((row["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entryKey)
                let text = (row["text"] as? String) ?? ""
                var parts: [MessagePart] = text.isEmpty ? [] : [.text(text)]
                for part in (row["attachments"] as? [[String: Any]]) ?? [] {
                    guard let ref = attachmentRef(part) else { continue }
                    _ = files.place(ref)
                    parts.append(.attachment(ref))
                }
                guard !parts.isEmpty, !keys.contains(key) else { continue }
                keys.insert(key)
                let createdAt = number(row["createdAt"])
                let hasFiles = parts.contains { if case .attachment = $0 { true } else { false } }
                out.sends.append(HomeCachedSend(
                    key: key, conversation: id, parts: parts,
                    issuedAt: createdAt > 0 ? Date(timeIntervalSince1970: createdAt / 1000) : Date(),
                    // A send with files comes back as one that may have been delivered, so the
                    // cache keeps it and Retry resends it under its key (the owner holds its uploads).
                    failed: hasFiles || ((row["failed"] as? Bool) ?? true),
                    threadRoot: (row["threadRoot"] as? String).map(MessageID.init(rawValue:)),
                    parent: (row["replyTo"] as? String).map(MessageID.init(rawValue:))))
            }
        }
        files.removeCopiedSources()
        out.draftAttachments = attachments.isEmpty ? nil : attachments
        return (out, true)
    }

    /// Where the page kept its parts' bytes: `<blob cache>-drafts`, beside the blob cache.
    static func keptDirectory(beside blobCache: URL) -> URL {
        blobCache.deletingLastPathComponent().appendingPathComponent(blobCache.lastPathComponent + "-drafts", isDirectory: true)
    }

    /// The page's kept bytes, copied into the blob cache once per destination file. A kept file is
    /// read again for every record that names its hash (under any extension) and removed only at
    /// the end, after each copy it feeds has landed.
    private struct KeptFiles {
        let kept: URL
        let blobCache: URL
        /// Hash to a blob cache file that already holds its bytes.
        var placed: [String: URL] = [:]
        /// Kept files every needed copy came from; a failed copy keeps its source here out.
        var copied: Set<String> = []
        var failed: Set<String> = []

        /// Where `ref`'s bytes are now: its blob cache file, or the kept file when the copy failed
        /// (or when no bytes were kept, the blob cache path the record has always named).
        mutating func place(_ ref: AttachmentRef) -> URL {
            let fm = FileManager.default
            let destination = AttachmentMedia.blobURL(root: blobCache, hash: ref.hash,
                                                      fileExtension: (ref.name as NSString).pathExtension.lowercased())
            if fm.fileExists(atPath: destination.path) {
                placed[ref.hash] = placed[ref.hash] ?? destination
                return destination
            }
            let source = kept.appendingPathComponent(ref.hash)
            let from = fm.fileExists(atPath: source.path) ? source : placed[ref.hash]
            guard let from, fm.fileExists(atPath: from.path) else { return destination }
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: from, to: destination)
                placed[ref.hash] = placed[ref.hash] ?? destination
                if from == source { copied.insert(ref.hash) }
                return destination
            } catch {
                failed.insert(ref.hash)
                return from
            }
        }

        /// Removes the kept files whose copies all landed, then the kept folder once it is empty.
        func removeCopiedSources() {
            let fm = FileManager.default
            for hash in copied.subtracting(failed) {
                try? fm.removeItem(at: kept.appendingPathComponent(hash))
            }
            if let left = try? fm.contentsOfDirectory(atPath: kept.path), left.isEmpty {
                try? fm.removeItem(at: kept)
            }
        }
    }

    /// The page's attachment part (`HomeAttachment`, camelCase) as a ref; nil without a hash.
    static func attachmentRef(_ part: [String: Any]) -> AttachmentRef? {
        guard let hash = part["hash"] as? String, !hash.isEmpty,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        func int(_ key: String) -> Int? { (part[key] as? NSNumber)?.intValue }
        return AttachmentRef(hash: hash, name: (part["name"] as? String) ?? hash,
                             mimeType: (part["mimeType"] as? String) ?? "application/octet-stream",
                             byteCount: int("byteCount") ?? 0, width: int("width"), height: int("height"),
                             durationMs: int("durationMs"), poster: derived(part["poster"]), preview: derived(part["preview"]))
    }

    /// A poster or preview the page's part named (camelCase or the owner's snake_case keys).
    private static func derived(_ value: Any?) -> AttachmentDerivedImage? {
        guard let object = value as? [String: Any], let hash = object["hash"] as? String, !hash.isEmpty else { return nil }
        let mimeType = (object["mimeType"] ?? object["mime_type"]) as? String ?? "application/octet-stream"
        let byteCount = ((object["byteCount"] ?? object["byte_count"]) as? NSNumber)?.intValue ?? 0
        return AttachmentDerivedImage(hash: hash, mimeType: mimeType, byteCount: byteCount)
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}
