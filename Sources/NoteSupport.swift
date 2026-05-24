import Foundation
import Darwin

// MARK: - Notes (project-scoped markdown notes at .cmux/notes/<slug>.md)

/// Helpers for the `note` surface type. Notes are plain markdown files stored
/// at `.cmux/notes/<slug>.md` relative to the project root.
enum NoteSupport {
    /// Max slug length. Filenames stay well under any FS limit and remain
    /// comfortably typable.
    static let maxSlugLength = 64
    private static let fileSystemQueue = DispatchQueue(label: "com.cmux.notes.filesystem", qos: .utility)

    /// Validate a user-supplied slug. Allowed: lowercase ASCII letters,
    /// digits, hyphens. Must start with a letter or digit. Length 1..=64.
    static func validateSlug(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NoteError.invalidSlug(String(localized: "note.error.slugEmpty", defaultValue: "slug is empty"))
        }
        guard trimmed.count <= maxSlugLength else {
            throw NoteError.invalidSlug(String(localized: "note.error.slugTooLong", defaultValue: "slug is longer than 64 characters"))
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw NoteError.invalidSlug(
                String(
                    localized: "note.error.slugInvalidChars",
                    defaultValue: "slug may contain only lowercase letters, digits, and hyphens"
                )
            )
        }
        guard let first = trimmed.first, first != "-" else {
            throw NoteError.invalidSlug(String(localized: "note.error.slugStartsWithHyphen", defaultValue: "slug must not start with a hyphen"))
        }
        return trimmed
    }

    /// Auto-generate a slug like `note-a3f2b1`. Six hex chars are enough to
    /// avoid practical collisions in a project's `.cmux/notes/` directory.
    static func autoSlug() -> String {
        let bytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "note-\(hex)"
    }

    /// Deterministic fallback for config-declared note surfaces without a
    /// valid slug. The seed should come from stable config structure, not
    /// runtime UUIDs.
    static func configFallbackSlug(seed: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }

        let rawHex = String(hash, radix: 16)
        let padding = String(repeating: "0", count: max(0, 16 - rawHex.count))
        let hex = String((padding + rawHex).suffix(12))
        return "note-config-\(hex)"
    }

    /// Find the nearest ancestor directory of `cwd` that already contains
    /// `.cmux/`. Falls back to `cwd` itself. Mirrors `findCmuxConfig` semantics
    /// so notes share a project root with `cmux.json`.
    static func projectRoot(forCwd cwd: String) -> String {
        let resolved = (cwd as NSString).standardizingPath
        var current = resolved
        let fs = FileManager.default
        while true {
            let cmuxDir = (current as NSString).appendingPathComponent(".cmux")
            var isDir: ObjCBool = false
            if fs.fileExists(atPath: cmuxDir, isDirectory: &isDir), isDir.boolValue {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return resolved
    }

    static func projectRootAsync(forCwd cwd: String) async -> String {
        await withCheckedContinuation { continuation in
            fileSystemQueue.async {
                continuation.resume(returning: projectRoot(forCwd: cwd))
            }
        }
    }

    /// Absolute path to the `.cmux/notes/` directory for a project root.
    static func notesDirectory(forProjectRoot root: String) -> String {
        ((root as NSString).appendingPathComponent(".cmux") as NSString)
            .appendingPathComponent("notes")
    }

    /// Absolute path to `<root>/.cmux/notes/<slug>.md` (does not create).
    static func notePath(forSlug slug: String, projectRoot: String) -> String {
        (notesDirectory(forProjectRoot: projectRoot) as NSString)
            .appendingPathComponent("\(slug).md")
    }

    /// Returns true only when the note path exists as a regular file. Directories,
    /// symlinks, and other special files are not note files.
    static func noteFileExists(forSlug slug: String, projectRoot: String) throws -> Bool {
        let path = notePath(forSlug: try validateSlug(slug), projectRoot: projectRoot)
        let fs = FileManager.default
        guard fs.fileExists(atPath: path) else { return false }
        guard isRegularFile(atPath: path) else {
            guard fs.fileExists(atPath: path) else { return false }
            throw NoteError.notRegularFile
        }
        return true
    }

    /// If `path` looks like a note (lives under `<root>/.cmux/notes/`), return
    /// the validated slug. Otherwise nil.
    static func slug(forNotePath path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        let parentName = (parent as NSString).lastPathComponent
        let grandparentName = ((parent as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard parentName == "notes", grandparentName == ".cmux" else { return nil }
        let filename = (standardized as NSString).lastPathComponent
        guard filename.hasSuffix(".md") else { return nil }
        let slug = String(filename.dropLast(3))
        return try? validateSlug(slug)
    }

    /// Pure path decomposition for a persisted note path. Unlike
    /// `projectRoot(forCwd:)`, this does not touch the filesystem, so it is
    /// safe to call from session snapshot and restore projections.
    static func projectRoot(forNotePath path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        let notesDirectory = (standardized as NSString).deletingLastPathComponent
        guard (notesDirectory as NSString).lastPathComponent == "notes" else { return nil }
        let cmuxDirectory = (notesDirectory as NSString).deletingLastPathComponent
        guard (cmuxDirectory as NSString).lastPathComponent == ".cmux" else { return nil }
        let projectRoot = (cmuxDirectory as NSString).deletingLastPathComponent
        return projectRoot.isEmpty ? nil : projectRoot
    }

    /// Pick the project root for restoring a persisted note snapshot without
    /// touching the filesystem. If the workspace cwd no longer lives under the
    /// stored note root, prefer the matching project-name ancestor from the cwd
    /// when present, otherwise fall back to the cwd so moved projects restore
    /// into the new tree.
    static func restoredProjectRoot(forStoredNotePath path: String, currentDirectory: String) -> String? {
        let standardizedCwd = (currentDirectory as NSString).standardizingPath
        guard !standardizedCwd.isEmpty else {
            return projectRoot(forNotePath: path)
        }
        guard let storedRoot = projectRoot(forNotePath: path) else {
            return standardizedCwd
        }
        let standardizedStoredRoot = (storedRoot as NSString).standardizingPath
        if standardizedCwd == standardizedStoredRoot ||
            standardizedCwd.hasPrefix(standardizedStoredRoot + "/") {
            return storedRoot
        }
        if let movedRoot = movedProjectRootMatchingStoredName(
            storedRoot: storedRoot,
            currentDirectory: standardizedCwd
        ) {
            return movedRoot
        }
        return standardizedCwd
    }

    private static func movedProjectRootMatchingStoredName(storedRoot: String, currentDirectory: String) -> String? {
        let storedName = (storedRoot as NSString).lastPathComponent
        guard !storedName.isEmpty else { return nil }

        let components = (currentDirectory as NSString).pathComponents
        guard let matchIndex = components.lastIndex(of: storedName) else {
            return nil
        }
        return NSString.path(withComponents: Array(components[...matchIndex]))
    }

    /// Project-root-aware reverse lookup for note files. This avoids treating an
    /// arbitrary `.cmux/notes/<slug>.md` path from another project as this
    /// workspace's note.
    static func slug(forNotePath path: String, projectRoot: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        let expectedParent = (notesDirectory(forProjectRoot: projectRoot) as NSString).standardizingPath
        guard parent == expectedParent else { return nil }
        return slug(forNotePath: standardized)
    }

    /// Ensure the `.cmux/notes/` directory and the `<slug>.md` file exist.
    /// Creates an empty file if missing. Returns the absolute path.
    @discardableResult
    static func ensureNoteFile(slug: String, projectRoot: String) throws -> String {
        let validatedSlug = try validateSlug(slug)
        let dir = notesDirectory(forProjectRoot: projectRoot)
        let fs = FileManager.default
        try fs.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let path = (dir as NSString).appendingPathComponent("\(validatedSlug).md")
        if fs.fileExists(atPath: path) {
            if isRegularFile(atPath: path) {
                return path
            }
            guard fs.fileExists(atPath: path) else {
                let created = fs.createFile(atPath: path, contents: Data(), attributes: nil)
                guard created || isRegularFile(atPath: path) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
                }
                return path
            }
            throw NoteError.notRegularFile
        } else {
            let created = fs.createFile(atPath: path, contents: Data(), attributes: nil)
            guard created || isRegularFile(atPath: path) else {
                if fs.fileExists(atPath: path) {
                    throw NoteError.notRegularFile
                }
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        }
        return path
    }

    struct NoteListEntry: Equatable {
        let slug: String
        let path: String
        let sizeBytes: Int64
        let mtime: Date
    }

    /// List notes in the project's `.cmux/notes/` directory, sorted by
    /// mtime descending. Returns an empty array if the directory does not
    /// exist.
    static func listNotes(forProjectRoot root: String) -> [NoteListEntry] {
        let dir = notesDirectory(forProjectRoot: root)
        let fs = FileManager.default
        guard let entries = try? fs.contentsOfDirectory(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        var notes: [NoteListEntry] = []
        for url in entries {
            let path = url.path
            guard path.hasSuffix(".md") else { continue }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard values?.isRegularFile == true else { continue }
            let filename = (path as NSString).lastPathComponent
            let slug = String(filename.dropLast(3))
            guard (try? validateSlug(slug)) != nil else { continue }
            notes.append(NoteListEntry(
                slug: slug,
                path: path,
                sizeBytes: Int64(values?.fileSize ?? 0),
                mtime: values?.contentModificationDate ?? .distantPast
            ))
        }
        return notes.sorted { $0.mtime > $1.mtime }
    }

    /// Delete the note file for `slug`. Returns true if a file was deleted.
    /// Returns false if the file was already absent (idempotent), including when
    /// another process removes it between the existence check and deletion.
    @discardableResult
    static func deleteNote(slug: String, projectRoot: String) throws -> Bool {
        let path = notePath(forSlug: try validateSlug(slug), projectRoot: projectRoot)
        let fs = FileManager.default
        guard fs.fileExists(atPath: path) else { return false }
        guard isRegularFile(atPath: path) else {
            guard fs.fileExists(atPath: path) else { return false }
            throw NoteError.notRegularFile
        }
        errno = 0
        let status = path.withCString { Darwin.unlink($0) }
        if status == 0 {
            return true
        }
        switch errno {
        case ENOENT:
            return false
        case EISDIR, EPERM:
            throw NoteError.notRegularFile
        default:
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isRegularFile(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    enum NoteError: Error, CustomStringConvertible, LocalizedError {
        case invalidSlug(String)
        case notRegularFile

        var description: String {
            switch self {
            case .invalidSlug(let reason):
                return String(
                    format: String(localized: "note.error.invalidSlug", defaultValue: "Invalid note slug: %@"),
                    locale: .current,
                    reason
                )
            case .notRegularFile:
                return String(localized: "note.error.notRegularFile", defaultValue: "Note path is not a regular file")
            }
        }

        var errorDescription: String? { description }
    }
}

// MARK: - cmux note index

struct CmuxNoteAttachment: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case workspace
        case surface
    }

    var kind: Kind
    var workspaceAnchorId: String
    var surfaceAnchorId: String?
    var surfaceKind: String?
    var createdAt: TimeInterval

    func matches(_ target: CmuxNoteAttachmentTarget) -> Bool {
        switch target {
        case .workspace(let workspaceAnchorId):
            return kind == .workspace && self.workspaceAnchorId == workspaceAnchorId
        case .surface(let workspaceAnchorId, let surfaceAnchorId, _):
            return kind == .surface &&
                self.workspaceAnchorId == workspaceAnchorId &&
                self.surfaceAnchorId == surfaceAnchorId
        }
    }
}

enum CmuxNoteAttachmentTarget: Equatable, Sendable {
    case workspace(workspaceAnchorId: String)
    case surface(workspaceAnchorId: String, surfaceAnchorId: String, surfaceKind: String)

    var attachment: CmuxNoteAttachment {
        switch self {
        case .workspace(let workspaceAnchorId):
            return CmuxNoteAttachment(
                kind: .workspace,
                workspaceAnchorId: workspaceAnchorId,
                surfaceAnchorId: nil,
                surfaceKind: nil,
                createdAt: Date().timeIntervalSince1970
            )
        case .surface(let workspaceAnchorId, let surfaceAnchorId, let surfaceKind):
            return CmuxNoteAttachment(
                kind: .surface,
                workspaceAnchorId: workspaceAnchorId,
                surfaceAnchorId: surfaceAnchorId,
                surfaceKind: surfaceKind,
                createdAt: Date().timeIntervalSince1970
            )
        }
    }
}

struct CmuxNoteRecord: Codable, Equatable, Sendable {
    var id: String
    var slug: String
    var title: String
    var bodyPath: String
    var attachments: [CmuxNoteAttachment]
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
}

struct CmuxNoteStoreResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var created: Bool
    var attached: Bool
}

struct CmuxNoteReadResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var content: String
}

struct CmuxNoteWriteResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var sizeBytes: Int64
}

enum CmuxNoteStoreError: Error, LocalizedError {
    case noteNotFound(slug: String)
    case corruptIndex(String)

    var errorDescription: String? {
        switch self {
        case .noteNotFound(let slug):
            return String(
                format: String(localized: "note.error.notFound", defaultValue: "Note not found: %@"),
                locale: .current,
                slug
            )
        case .corruptIndex(let detail):
            return String(
                format: String(localized: "note.error.corruptIndex", defaultValue: "Note index is invalid: %@"),
                locale: .current,
                detail
            )
        }
    }
}

enum CmuxNoteStore {
    private struct IndexFile: Codable, Sendable {
        var version: Int
        var notes: [CmuxNoteRecord]
    }

    private static let schemaVersion = 1
    private static let indexFileName = "index.json"
    private static let storageQueue = DispatchQueue(label: "com.cmux.notes.store")

    static func newAnchorID() -> String {
        "anchor-\(UUID().uuidString.lowercased())"
    }

    static func indexPath(forProjectRoot root: String) -> String {
        (NoteSupport.notesDirectory(forProjectRoot: root) as NSString)
            .appendingPathComponent(indexFileName)
    }

    static func absoluteBodyPath(bodyPath: String, projectRoot: String) -> String {
        if bodyPath.hasPrefix("/") {
            return (bodyPath as NSString).standardizingPath
        }
        return (((projectRoot as NSString).appendingPathComponent(".cmux") as NSString)
            .appendingPathComponent(bodyPath) as NSString)
            .standardizingPath
    }

    static func noteBodyPath(for note: CmuxNoteRecord, projectRoot: String) -> String {
        absoluteBodyPath(bodyPath: note.bodyPath, projectRoot: projectRoot)
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

    static func list(projectRoot: String) -> [CmuxNoteRecord] {
        storageQueue.sync {
            (try? loadIndex(projectRoot: projectRoot).notes.sorted(by: { lhs, rhs in
                noteMTime(lhs, projectRoot: projectRoot) > noteMTime(rhs, projectRoot: projectRoot)
            })) ?? []
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

    @discardableResult
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
                // The index is the durable source of truth. Once it no longer
                // references the note, body-file cleanup is best effort so a
                // cleanup failure cannot make the original delete fail after
                // retries would already report "not found".
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
           let existing = index.notes.first(where: { note in
               note.attachments.contains(where: { $0.matches(target) })
           }) {
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
        let path = indexPath(forProjectRoot: projectRoot)
        let fs = FileManager.default
        let legacy = legacyNotes(projectRoot: projectRoot)
        guard fs.fileExists(atPath: path) else {
            return IndexFile(version: schemaVersion, notes: legacy)
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var index = try JSONDecoder().decode(IndexFile.self, from: data)
            index.notes = mergeLegacyNotes(legacy, into: index.notes)
            return index
        } catch {
            throw CmuxNoteStoreError.corruptIndex(error.localizedDescription)
        }
    }

    private static func writeIndex(_ index: IndexFile, projectRoot: String) throws {
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
