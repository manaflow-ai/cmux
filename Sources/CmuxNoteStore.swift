import Foundation
import Darwin

// MARK: - cmux note index store

enum CmuxNoteStore {
    typealias IndexFile = CmuxNoteIndexFile

    static let schemaVersion = 1
    static let indexFileName = "index.json"
    static let indexDataReader = CmuxNoteIndexDataReader(maxBytes: 8 * 1024 * 1024)
    static let storageQueue = DispatchQueue(label: "com.cmux.notes.store")

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
}


extension NoteSupport {
    static func noteFileExists(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }
}
