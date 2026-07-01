import Foundation
import Darwin

// MARK: - cmux note index store

enum CmuxNoteStore {
    private typealias IndexFile = CmuxNoteIndexFile

    private static let schemaVersion = 1
    private static let indexFileName = "index.json"
    private static let indexDataReader = CmuxNoteIndexDataReader(maxBytes: 8 * 1024 * 1024)
    private static let storageQueue = DispatchQueue(label: "com.cmux.notes.store")

    static func newAnchorID() -> String {
        "anchor-\(UUID().uuidString.lowercased())"
    }

    static func indexPath(forProjectRoot root: String) -> String {
        (NoteSupport.notesDirectory(forProjectRoot: root) as NSString)
            .appendingPathComponent(indexFileName)
    }

    static func createOrOpen(
        slug rawSlug: String?,
        title rawTitle: String? = nil,
        projectRoot: String,
        createIfMissing: Bool,
        attachment target: CmuxNoteAttachmentTarget? = nil,
        preferAttachedExisting: Bool = false
    ) throws -> CmuxNoteStoreResult {
        try withStoreLock {
            try createOrOpenUnlocked(
                slug: rawSlug,
                title: rawTitle,
                projectRoot: projectRoot,
                createIfMissing: createIfMissing,
                attachment: target,
                preferAttachedExisting: preferAttachedExisting
            )
        }
    }

    static func createOrOpenAsync(
        slug rawSlug: String?,
        title rawTitle: String? = nil,
        projectRoot: String,
        createIfMissing: Bool,
        attachment target: CmuxNoteAttachmentTarget? = nil,
        preferAttachedExisting: Bool = false
    ) async throws -> CmuxNoteStoreResult {
        try await withStoreLockAsync {
            try createOrOpenUnlocked(
                slug: rawSlug,
                title: rawTitle,
                projectRoot: projectRoot,
                createIfMissing: createIfMissing,
                attachment: target,
                preferAttachedExisting: preferAttachedExisting
            )
        }
    }

    static func list(projectRoot: String) throws -> [CmuxNoteRecord] {
        // Propagate a corrupt/unreadable index instead of returning an empty list,
        // so `cmux note list` surfaces the error rather than making notes look gone.
        try withStoreLock {
            let notes = try loadIndex(projectRoot: projectRoot).notes
            // Stat each body once up front; a comparator that stats on every
            // comparison re-reads the filesystem O(n log n) times.
            // Tolerate duplicate ids (the index is a project-controlled file).
            let mtimes = Dictionary(
                notes.map { ($0.id, noteMTime($0, projectRoot: projectRoot)) },
                uniquingKeysWith: { first, _ in first }
            )
            return notes.sorted { (mtimes[$0.id] ?? .distantPast) > (mtimes[$1.id] ?? .distantPast) }
        }
    }

    static func path(slug rawSlug: String, projectRoot: String) throws -> (note: CmuxNoteRecord, path: String, exists: Bool) {
        try withStoreLock {
            let slug = try NoteSupport.validateSlug(rawSlug)
            let index = try loadIndex(projectRoot: projectRoot)
            guard let note = index.notes.first(where: { $0.slug == slug }) else {
                throw CmuxNoteStoreError.noteNotFound(slug: slug)
            }
            let path = noteBodyPath(for: note, projectRoot: projectRoot)
            return (note, path, NoteSupport.noteFileExists(atPath: path))
        }
    }

    static func read(slug rawSlug: String, projectRoot: String) throws -> CmuxNoteReadResult {
        try withStoreLock {
            let resolved = try pathUnlocked(slug: rawSlug, projectRoot: projectRoot)
            try requireExistingBodyFile(atPath: resolved.path, slug: resolved.note.slug)
            let content = try String(contentsOfFile: resolved.path, encoding: .utf8)
            return CmuxNoteReadResult(note: resolved.note, path: resolved.path, content: content)
        }
    }

    static func write(
        slug rawSlug: String,
        title rawTitle: String? = nil,
        content: String,
        projectRoot: String,
        createIfMissing: Bool = true
    ) throws -> CmuxNoteWriteResult {
        try withStoreLock {
            try writeContentUnlocked(
                slug: rawSlug,
                title: rawTitle,
                content: content,
                projectRoot: projectRoot,
                createIfMissing: createIfMissing,
                append: false
            )
        }
    }

    static func append(
        slug rawSlug: String,
        title rawTitle: String? = nil,
        content: String,
        projectRoot: String,
        createIfMissing: Bool = true
    ) throws -> CmuxNoteWriteResult {
        try withStoreLock {
            try writeContentUnlocked(
                slug: rawSlug,
                title: rawTitle,
                content: content,
                projectRoot: projectRoot,
                createIfMissing: createIfMissing,
                append: true
            )
        }
    }

    /// Set a note's display title without touching its body file. The record
    /// title is what the Notes tree and `cmux note list` show for index-owned
    /// notes (their body filenames are store-managed), so this is their
    /// "rename". The title is whitespace-trimmed; an empty result keeps the
    /// current title (parity with the tree rejecting empty file names).
    @discardableResult
    static func retitle(
        slug rawSlug: String,
        projectRoot: String,
        title rawTitle: String
    ) throws -> CmuxNoteRecord {
        try withStoreLock {
            let slug = try NoteSupport.validateSlug(rawSlug)
            var index = try loadIndex(projectRoot: projectRoot)
            guard let noteIndex = index.notes.firstIndex(where: { $0.slug == slug }) else {
                throw CmuxNoteStoreError.noteNotFound(slug: slug)
            }
            let title = normalizedTitle(rawTitle, fallback: index.notes[noteIndex].title)
            guard title != index.notes[noteIndex].title else { return index.notes[noteIndex] }
            index.notes[noteIndex].title = title
            index.notes[noteIndex].updatedAt = Date().timeIntervalSince1970
            try writeIndex(index, projectRoot: projectRoot)
            return index.notes[noteIndex]
        }
    }

    /// Attach an existing note body to a workspace or surface target. If the
    /// body is not indexed yet (for example, a plain `.md` file from the Notes
    /// tree), adopt it into `index.json` without moving the file.
    @discardableResult
    static func attachBodyPath(
        _ rawPath: String,
        projectRoot: String,
        to target: CmuxNoteAttachmentTarget,
        title rawTitle: String? = nil
    ) throws -> CmuxNoteRecord {
        try withStoreLock {
            let path = ((rawPath as NSString).standardizingPath as NSString)
                .resolvingSymlinksInPath
            let notesRoot = ((NoteSupport.notesDirectory(forProjectRoot: projectRoot) as NSString)
                .standardizingPath as NSString).resolvingSymlinksInPath
            guard path.hasPrefix(notesRoot + "/") else {
                throw CmuxNoteStoreError.noteNotFound(slug: (rawPath as NSString).lastPathComponent)
            }
            guard NoteSupport.noteFileExists(atPath: path) else {
                throw NoteSupport.NoteError.notRegularFile
            }

            let workspaceAnchorId: String
            switch target {
            case .workspace(let anchorId), .surface(let anchorId, _, _):
                workspaceAnchorId = anchorId
            }

            var index = try loadIndex(projectRoot: projectRoot)
            let now = Date().timeIntervalSince1970
            if let recordIndex = index.notes.firstIndex(where: {
                noteBodyPath(for: $0, projectRoot: projectRoot) == path
            }) {
                var record = index.notes[recordIndex]
                let existingTargetAttachment = record.attachments.first { $0.matches(target) }
                let retained = record.attachments.filter { $0.workspaceAnchorId != workspaceAnchorId }
                let updatedAttachments = retained + [existingTargetAttachment ?? target.attachment]
                guard updatedAttachments != record.attachments else { return record }
                record.attachments = updatedAttachments
                record.updatedAt = now
                index.notes[recordIndex] = record
                try writeIndex(index, projectRoot: projectRoot)
                return record
            }

            let fileName = (path as NSString).lastPathComponent
            let displayTitle = (fileName as NSString).deletingPathExtension
            let slug = uniqueSlug(preferredName: displayTitle, in: index.notes)
            let record = CmuxNoteRecord(
                id: UUID().uuidString.lowercased(),
                slug: slug,
                title: normalizedTitle(rawTitle, fallback: displayTitle.isEmpty ? slug : displayTitle),
                bodyPath: relativeBodyPath(forAbsolutePath: path, projectRoot: projectRoot),
                attachments: [target.attachment],
                createdAt: now,
                updatedAt: now
            )
            index.notes.append(record)
            try writeIndex(index, projectRoot: projectRoot)
            return record
        }
    }

    @discardableResult
    /// Move a note's body file into `directory` (confined to `.cmux/notes`)
    /// and update the index's `bodyPath` in the same locked transaction, so
    /// `cmux note` and the Notes tree stay consistent — moving only the file
    /// would orphan the index record. Returns the new absolute body path.
    static func relocateBody(
        slug rawSlug: String,
        projectRoot: String,
        toDirectory directory: String
    ) throws -> String {
        try withStoreLock {
            let slug = try NoteSupport.validateSlug(rawSlug)
            var index = try loadIndex(projectRoot: projectRoot)
            guard let recordIndex = index.notes.firstIndex(where: { $0.slug == slug }) else {
                throw CmuxNoteStoreError.noteNotFound(slug: slug)
            }
            let notesRoot = ((NoteSupport.notesDirectory(forProjectRoot: projectRoot) as NSString)
                .standardizingPath as NSString).resolvingSymlinksInPath
            let destDir = (((directory as NSString).standardizingPath as NSString)
                .resolvingSymlinksInPath)
            guard destDir == notesRoot || destDir.hasPrefix(notesRoot + "/") else {
                throw CmuxNoteStoreError.noteNotFound(slug: slug)
            }
            let currentPath = absoluteBodyPath(bodyPath: index.notes[recordIndex].bodyPath, projectRoot: projectRoot)
            let fm = FileManager.default
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            let baseName = (currentPath as NSString).lastPathComponent
            var destPath = (destDir as NSString).appendingPathComponent(baseName)
            var counter = 2
            while fm.fileExists(atPath: destPath) {
                let stem = (baseName as NSString).deletingPathExtension
                let ext = (baseName as NSString).pathExtension
                let candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                destPath = (destDir as NSString).appendingPathComponent(candidate)
                counter += 1
            }
            // bodyPath is stored relative to `<projectRoot>/.cmux`.
            let cmuxDir = ((projectRoot as NSString).appendingPathComponent(".cmux") as NSString)
                .standardizingPath
            var relative = destPath
            if relative.hasPrefix(cmuxDir + "/") {
                relative = String(relative.dropFirst(cmuxDir.count + 1))
            }
            let originalIndex = index
            index.notes[recordIndex].bodyPath = relative
            index.notes[recordIndex].updatedAt = Date().timeIntervalSince1970
            try writeIndex(index, projectRoot: projectRoot)
            do {
                if fm.fileExists(atPath: currentPath) {
                    try fm.moveItem(atPath: currentPath, toPath: destPath)
                } else {
                    try ensureBodyFile(atPath: destPath)
                }
            } catch {
                try? writeIndex(originalIndex, projectRoot: projectRoot)
                throw error
            }
            return destPath
        }
    }

    /// Rewrite indexed `bodyPath`s after a Notes-tree move/rename relocated
    /// `fromAbsolutePath` (a file, or a directory whose subtree may contain
    /// indexed bodies) to `toAbsolutePath` with a plain filesystem move.
    /// Without this, the first drag of an indexed note into the tree makes
    /// every later tree move of it (or of a folder above it) silently orphan
    /// the index record. No-op when nothing is indexed under the old path.
    static func rebaseBodyPaths(
        projectRoot: String,
        fromAbsolutePath: String,
        toAbsolutePath: String
    ) throws {
        try withStoreLock {
            let from = ((fromAbsolutePath as NSString).standardizingPath as NSString)
                .resolvingSymlinksInPath
            let to = ((toAbsolutePath as NSString).standardizingPath as NSString)
                .resolvingSymlinksInPath
            guard from != to else { return }
            var index = try loadIndex(projectRoot: projectRoot)
            let cmuxDir = ((projectRoot as NSString).appendingPathComponent(".cmux") as NSString)
                .standardizingPath
            let now = Date().timeIntervalSince1970
            var changed = false
            for i in index.notes.indices {
                let current = noteBodyPath(for: index.notes[i], projectRoot: projectRoot)
                let rebased: String
                if current == from {
                    rebased = to
                } else if current.hasPrefix(from + "/") {
                    rebased = to + String(current.dropFirst(from.count))
                } else {
                    continue
                }
                // bodyPath is stored relative to `<projectRoot>/.cmux`.
                var relative = rebased
                if relative.hasPrefix(cmuxDir + "/") {
                    relative = String(relative.dropFirst(cmuxDir.count + 1))
                }
                index.notes[i].bodyPath = relative
                index.notes[i].updatedAt = now
                changed = true
            }
            if changed {
                try writeIndex(index, projectRoot: projectRoot)
            }
        }
    }

    /// Drop index records whose body lives at or under `absolutePath` — used
    /// after the Notes tree trashes a file/folder so `cmux note list` does not
    /// keep advertising notes whose bodies are in the Trash.
    @discardableResult
    static func removeRecords(underAbsolutePath absolutePath: String, projectRoot: String) throws -> [CmuxNoteRecord] {
        try withStoreLock {
            let target = ((absolutePath as NSString).standardizingPath as NSString)
                .resolvingSymlinksInPath
            var index = try loadIndex(projectRoot: projectRoot)
            var removed: [CmuxNoteRecord] = []
            index.notes.removeAll { note in
                let path = noteBodyPath(for: note, projectRoot: projectRoot)
                guard path == target || path.hasPrefix(target + "/") else {
                    return false
                }
                removed.append(note)
                return true
            }
            if !removed.isEmpty {
                try writeIndex(index, projectRoot: projectRoot)
            }
            return removed
        }
    }

    static func restoreRecords(_ records: [CmuxNoteRecord], projectRoot: String) throws {
        guard !records.isEmpty else { return }
        try withStoreLock {
            var index = try loadIndex(projectRoot: projectRoot)
            var existingIds = Set(index.notes.map(\.id))
            var existingSlugs = Set(index.notes.map(\.slug))
            var changed = false
            for record in records where !existingIds.contains(record.id) && !existingSlugs.contains(record.slug) {
                index.notes.append(record)
                existingIds.insert(record.id)
                existingSlugs.insert(record.slug)
                changed = true
            }
            if changed {
                try writeIndex(index, projectRoot: projectRoot)
            }
        }
    }

    static func delete(slug rawSlug: String, projectRoot: String) throws -> Bool {
        try withStoreLock {
            let slug = try NoteSupport.validateSlug(rawSlug)
            var index = try loadIndex(projectRoot: projectRoot)
            guard let noteIndex = index.notes.firstIndex(where: { $0.slug == slug }) else {
                return false
            }
            let note = index.notes.remove(at: noteIndex)
            let path = noteBodyPath(for: note, projectRoot: projectRoot)
            try writeIndex(index, projectRoot: projectRoot)
            do {
                _ = try deleteBodyIfPresent(atPath: path)
            } catch {
                index.notes.insert(note, at: min(noteIndex, index.notes.count))
                try? writeIndex(index, projectRoot: projectRoot)
                // Keep the note reachable when body cleanup fails; callers can
                // retry after fixing permissions or replacing a non-file body.
                throw error
            }
            return true
        }
    }

    private static func withStoreLock<T>(_ work: () throws -> T) rethrows -> T {
        try storageQueue.sync(execute: work)
    }

    private static func withStoreLockAsync<T: Sendable>(
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

    private static func createOrOpenUnlocked(
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

    private static func pathUnlocked(slug rawSlug: String, projectRoot: String) throws -> (note: CmuxNoteRecord, path: String, exists: Bool) {
        let slug = try NoteSupport.validateSlug(rawSlug)
        let index = try loadIndex(projectRoot: projectRoot)
        guard let note = index.notes.first(where: { $0.slug == slug }) else {
            throw CmuxNoteStoreError.noteNotFound(slug: slug)
        }
        let path = noteBodyPath(for: note, projectRoot: projectRoot)
        return (note, path, NoteSupport.noteFileExists(atPath: path))
    }

    private static func ensureResult(
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

    private static func writeContentUnlocked(
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

    private static func updateNoteMetadataUnlocked(
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

    private static func loadIndex(projectRoot: String) throws -> IndexFile {
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

    private static func writeIndex(_ index: IndexFile, projectRoot: String) throws {
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

    private static func legacyNotes(projectRoot: String) -> [CmuxNoteRecord] {
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

    private static func mergeLegacyNotes(_ legacy: [CmuxNoteRecord], into indexed: [CmuxNoteRecord]) -> [CmuxNoteRecord] {
        var merged = indexed
        let indexedBodyPaths = Set(indexed.map(\.bodyPath))
        let indexedSlugs = Set(indexed.map(\.slug))
        for note in legacy where !indexedBodyPaths.contains(note.bodyPath) && !indexedSlugs.contains(note.slug) {
            merged.append(note)
        }
        return merged
    }

    private static func uniqueAutoSlug(in notes: [CmuxNoteRecord]) -> String {
        let used = Set(notes.map(\.slug))
        while true {
            let slug = NoteSupport.autoSlug()
            if !used.contains(slug) {
                return slug
            }
        }
    }

    private static func uniqueSlug(preferredName: String, in notes: [CmuxNoteRecord]) -> String {
        let used = Set(notes.map(\.slug))
        if let preferred = slugCandidate(from: preferredName), !used.contains(preferred) {
            return preferred
        }
        while true {
            let slug = NoteSupport.autoSlug()
            if !used.contains(slug) { return slug }
        }
    }

    private static func slugCandidate(from name: String) -> String? {
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

    private static func relativeBodyPath(forAbsolutePath path: String, projectRoot: String) -> String {
        let cmuxDir = ((projectRoot as NSString).appendingPathComponent(".cmux") as NSString)
            .standardizingPath
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(cmuxDir + "/") else { return standardized }
        return String(standardized.dropFirst(cmuxDir.count + 1))
    }

    private static func normalizedTitle(_ rawTitle: String?, fallback: String) -> String {
        let trimmed = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func ensureBodyFile(atPath path: String) throws {
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

    private static func deleteBodyIfPresent(atPath path: String) throws -> Bool {
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

    private static func requireExistingBodyFile(atPath path: String, slug: String) throws {
        let fs = FileManager.default
        guard fs.fileExists(atPath: path) else {
            throw CmuxNoteStoreError.noteNotFound(slug: slug)
        }
        guard NoteSupport.noteFileExists(atPath: path) else {
            throw NoteSupport.NoteError.notRegularFile
        }
    }

    private static func fileSize(atPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func noteMTime(_ note: CmuxNoteRecord, projectRoot: String) -> Date {
        let url = URL(fileURLWithPath: noteBodyPath(for: note, projectRoot: projectRoot))
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
            Date(timeIntervalSince1970: note.updatedAt)
    }
}

private extension NoteSupport {
    static func noteFileExists(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }
}
