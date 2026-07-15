import Foundation

extension CmuxNoteStore {
    static func withStoreLock<T>(_ work: () throws -> T) rethrows -> T {
        try storageQueue.sync(execute: work)
    }

    static func withStoreLockAsync<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            storageQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func createOrOpenUnlocked(
        slug rawSlug: String?,
        title rawTitle: String? = nil,
        projectRoot: String,
        createIfMissing: Bool,
        attachment target: CmuxNoteAttachmentTarget? = nil,
        preferAttachedExisting: Bool = false
    ) throws -> CmuxNoteStoreResult {
        var index = try loadIndex(projectRoot: projectRoot)

        if preferAttachedExisting,
           rawSlug == nil,
           let target,
           // Reuse the most-recently-updated note linked to this target so the
           // pick matches CmuxNoteContextResolver (note here / note list).
           let existing = index.notes
               .filter({ note in note.attachments.contains(where: { $0.matches(target) }) })
               .max(by: { $0.updatedAt < $1.updatedAt }) {
            return try ensureResult(
                note: existing,
                projectRoot: projectRoot,
                createIfMissing: createIfMissing,
                index: &index,
                attachment: target
            )
        }

        let slug: String
        if let rawSlug {
            slug = try NoteSupport.validateSlug(rawSlug)
        } else {
            slug = uniqueAutoSlug(in: index.notes)
        }

        if let existing = index.notes.first(where: { $0.slug == slug }) {
            return try ensureResult(
                note: existing,
                projectRoot: projectRoot,
                createIfMissing: createIfMissing,
                index: &index,
                attachment: target
            )
        }

        guard createIfMissing else {
            throw CmuxNoteStoreError.noteNotFound(slug: slug)
        }

        let now = Date().timeIntervalSince1970
        let id = UUID().uuidString.lowercased()
        let title = normalizedTitle(rawTitle, fallback: slug)
        let record = CmuxNoteRecord(
            id: id,
            slug: slug,
            title: title,
            bodyPath: "notes/\(id).md",
            attachments: target.map { [$0.attachment] } ?? [],
            createdAt: now,
            updatedAt: now
        )
        let path = noteBodyPath(for: record, projectRoot: projectRoot)
        try ensureBodyFile(atPath: path)
        index.notes.append(record)
        try writeIndex(index, projectRoot: projectRoot)
        return CmuxNoteStoreResult(note: record, path: path, created: true, attached: target != nil)
    }

    static func pathUnlocked(slug rawSlug: String, projectRoot: String) throws -> (note: CmuxNoteRecord, path: String, exists: Bool) {
        let slug = try NoteSupport.validateSlug(rawSlug)
        let index = try loadIndex(projectRoot: projectRoot)
        guard let note = index.notes.first(where: { $0.slug == slug }) else {
            throw CmuxNoteStoreError.noteNotFound(slug: slug)
        }
        let path = noteBodyPath(for: note, projectRoot: projectRoot)
        return (note, path, NoteSupport.noteFileExists(atPath: path))
    }

    static func ensureResult(
        note: CmuxNoteRecord,
        projectRoot: String,
        createIfMissing: Bool,
        index: inout IndexFile,
        attachment target: CmuxNoteAttachmentTarget?
    ) throws -> CmuxNoteStoreResult {
        var note = note
        let path = noteBodyPath(for: note, projectRoot: projectRoot)
        let exists = NoteSupport.noteFileExists(atPath: path)
        if createIfMissing, !exists {
            try ensureBodyFile(atPath: path)
        } else if !createIfMissing, !exists {
            throw CmuxNoteStoreError.noteNotFound(slug: note.slug)
        }

        var didAttach = false
        if let target, !note.attachments.contains(where: { $0.matches(target) }) {
            note.attachments.append(target.attachment)
            note.updatedAt = Date().timeIntervalSince1970
            didAttach = true
            if let noteIndex = index.notes.firstIndex(where: { $0.id == note.id }) {
                index.notes[noteIndex] = note
            }
            try writeIndex(index, projectRoot: projectRoot)
        }
        return CmuxNoteStoreResult(note: note, path: path, created: false, attached: didAttach)
    }

    static func writeContentUnlocked(
        slug rawSlug: String,
        title rawTitle: String?,
        content: String,
        projectRoot: String,
        createIfMissing: Bool,
        append: Bool
    ) throws -> CmuxNoteWriteResult {
        let opened = try createOrOpenUnlocked(
            slug: rawSlug,
            title: rawTitle,
            projectRoot: projectRoot,
            createIfMissing: createIfMissing
        )
        try requireExistingBodyFile(atPath: opened.path, slug: opened.note.slug)

        if append {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: opened.path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(content.utf8))
        } else {
            try content.write(toFile: opened.path, atomically: true, encoding: .utf8)
        }

        let updatedNote = try updateNoteMetadataUnlocked(
            noteID: opened.note.id,
            projectRoot: projectRoot
        ) { note in
            note.updatedAt = Date().timeIntervalSince1970
        }
        return CmuxNoteWriteResult(
            note: updatedNote,
            path: opened.path,
            sizeBytes: fileSize(atPath: opened.path)
        )
    }

    static func updateNoteMetadataUnlocked(
        noteID: String,
        projectRoot: String,
        update: (inout CmuxNoteRecord) -> Void
    ) throws -> CmuxNoteRecord {
        var index = try loadIndex(projectRoot: projectRoot)
        guard let noteIndex = index.notes.firstIndex(where: { $0.id == noteID }) else {
            throw CmuxNoteStoreError.noteNotFound(slug: noteID)
        }
        update(&index.notes[noteIndex])
        let note = index.notes[noteIndex]
        try writeIndex(index, projectRoot: projectRoot)
        return note
    }

    static func loadIndex(projectRoot: String) throws -> IndexFile {
        // Every store operation reads the index first (and writes through
        // writeIndex), so gating both here keeps all note IO behind the
        // symlinked-`.cmux/notes` trust check.
        guard NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) else {
            throw CmuxNoteStoreError.untrustedNotesDirectory
        }
        let path = indexPath(forProjectRoot: projectRoot)
        let legacy = legacyNotes(projectRoot: projectRoot)
        do {
            guard let data = try indexDataReader.readIfPresent(atPath: path) else {
                return IndexFile(version: schemaVersion, notes: legacy)
            }
            var index = try JSONDecoder().decode(IndexFile.self, from: data)
            index.notes = mergeLegacyNotes(legacy, into: index.notes)
            return index
        } catch {
            throw CmuxNoteStoreError.corruptIndex(error.localizedDescription)
        }
    }

    static func writeIndex(_ index: IndexFile, projectRoot: String) throws {
        guard NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) else {
            throw CmuxNoteStoreError.untrustedNotesDirectory
        }
        let dir = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        let fs = FileManager.default
        try fs.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(IndexFile(version: schemaVersion, notes: index.notes))
        try data.write(to: URL(fileURLWithPath: indexPath(forProjectRoot: projectRoot)), options: [.atomic])
    }

    static func legacyNotes(projectRoot: String) -> [CmuxNoteRecord] {
        NoteSupport.listNotes(forProjectRoot: projectRoot).compactMap { entry in
            let filename = (entry.path as NSString).lastPathComponent
            guard filename != indexFileName else { return nil }
            let now = entry.mtime.timeIntervalSince1970
            return CmuxNoteRecord(
                id: "legacy-\(entry.slug)",
                slug: entry.slug,
                title: entry.slug,
                bodyPath: "notes/\(filename)",
                attachments: [],
                createdAt: now,
                updatedAt: now
            )
        }
    }

    static func mergeLegacyNotes(_ legacy: [CmuxNoteRecord], into indexed: [CmuxNoteRecord]) -> [CmuxNoteRecord] {
        var merged = indexed
        let indexedBodyPaths = Set(indexed.map(\.bodyPath))
        let indexedSlugs = Set(indexed.map(\.slug))
        for note in legacy where !indexedBodyPaths.contains(note.bodyPath) && !indexedSlugs.contains(note.slug) {
            merged.append(note)
        }
        return merged
    }

    static func uniqueAutoSlug(in notes: [CmuxNoteRecord]) -> String {
        let used = Set(notes.map(\.slug))
        while true {
            let slug = NoteSupport.autoSlug()
            if !used.contains(slug) {
                return slug
            }
        }
    }

    static func uniqueSlug(preferredName: String, in notes: [CmuxNoteRecord]) -> String {
        let used = Set(notes.map(\.slug))
        if let preferred = slugCandidate(from: preferredName), !used.contains(preferred) {
            return preferred
        }
        while true {
            let slug = NoteSupport.autoSlug()
            if !used.contains(slug) { return slug }
        }
    }

    static func slugCandidate(from name: String) -> String? {
        var output = ""
        var lastWasHyphen = false
        for scalar in name.lowercased().unicodeScalars {
            let value = scalar.value
            let isAllowed = (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
            if isAllowed {
                output.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                output.append("-")
                lastWasHyphen = true
            }
            if output.count >= NoteSupport.maxSlugLength { break }
        }
        let candidate = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return try? NoteSupport.validateSlug(candidate)
    }

    static func relativeBodyPath(forAbsolutePath path: String, projectRoot: String) -> String {
        let cmuxDir = ((projectRoot as NSString).appendingPathComponent(".cmux") as NSString)
            .standardizingPath
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(cmuxDir + "/") else { return standardized }
        return String(standardized.dropFirst(cmuxDir.count + 1))
    }

    static func normalizedTitle(_ rawTitle: String?, fallback: String) -> String {
        let trimmed = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func ensureBodyFile(atPath path: String) throws {
        let fs = FileManager.default
        try fs.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if fs.fileExists(atPath: path) {
            guard NoteSupport.noteFileExists(atPath: path) else {
                throw NoteSupport.NoteError.notRegularFile
            }
            return
        }
        let created = fs.createFile(atPath: path, contents: Data(), attributes: nil)
        guard created || NoteSupport.noteFileExists(atPath: path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
    }

    static func deleteBodyIfPresent(atPath path: String) throws -> Bool {
        let fs = FileManager.default
        guard fs.fileExists(atPath: path) else { return false }
        guard NoteSupport.noteFileExists(atPath: path) else {
            guard fs.fileExists(atPath: path) else { return false }
            throw NoteSupport.NoteError.notRegularFile
        }
        errno = 0
        let status = path.withCString { Darwin.unlink($0) }
        if status == 0 { return true }
        switch errno {
        case ENOENT:
            return false
        case EISDIR, EPERM:
            throw NoteSupport.NoteError.notRegularFile
        default:
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func requireExistingBodyFile(atPath path: String, slug: String) throws {
        let fs = FileManager.default
        guard fs.fileExists(atPath: path) else {
            throw CmuxNoteStoreError.noteNotFound(slug: slug)
        }
        guard NoteSupport.noteFileExists(atPath: path) else {
            throw NoteSupport.NoteError.notRegularFile
        }
    }

    static func fileSize(atPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func noteMTime(_ note: CmuxNoteRecord, projectRoot: String) -> Date {
        let url = URL(fileURLWithPath: noteBodyPath(for: note, projectRoot: projectRoot))
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
            Date(timeIntervalSince1970: note.updatedAt)
    }
}
