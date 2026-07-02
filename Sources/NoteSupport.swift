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

    /// `.cmux` and `.cmux/notes` must be real directories (when present): a
    /// repository committing either as a symlink would re-root the notes
    /// containment boundary wherever the link points, and note IO could then
    /// read or overwrite files outside the project's notes directory.
    /// Ancestor symlinks (e.g. `/tmp -> /private/tmp`) stay legal — only the
    /// two project-controlled components are checked.
    static func projectNotesDirectoryIsTrusted(projectRoot root: String) -> Bool {
        let fm = FileManager.default
        let cmuxDir = (root as NSString).appendingPathComponent(".cmux")
        let notesDir = (cmuxDir as NSString).appendingPathComponent("notes")
        for path in [cmuxDir, notesDir] {
            if ((try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink {
                return false
            }
        }
        return true
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
    /// safe to call from session snapshot and restore projections. Matches the
    /// last `.cmux/notes` segment anywhere in the path so notes relocated into
    /// the Notes tree (`<root>/.cmux/notes/<workspace>/<folder>/x.md`) resolve
    /// the same project root as flat notes.
    static func projectRoot(forNotePath path: String) -> String? {
        let components = ((path as NSString).standardizingPath as NSString).pathComponents
        var index = components.count - 2
        while index >= 1 {
            if components[index] == "notes", components[index - 1] == ".cmux" {
                let rootComponents = Array(components[..<(index - 1)])
                guard !rootComponents.isEmpty else { return nil }
                let root = NSString.path(withComponents: rootComponents)
                return root.isEmpty || root == "/" ? nil : root
            }
            index -= 1
        }
        return nil
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

    typealias NoteListEntry = NoteSupportListEntry

    /// List notes in the project's `.cmux/notes/` directory, sorted by
    /// mtime descending. Returns an empty array if the directory does not
    /// exist.
    ///
    /// Bounded: the streaming enumerator materializes (stats + sorts) at most
    /// `limit` entries, so this scan — reached from every note-store read via
    /// the unindexed-note merge — stays cheap even if a project-controlled
    /// `.cmux/notes` directory is huge. Beyond the cap, selection follows
    /// filesystem order; the cap is far above any practical flat-note count.
    static func listNotes(forProjectRoot root: String, limit: Int = 2000) -> [NoteListEntry] {
        let dir = notesDirectory(forProjectRoot: root)
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dir, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        var notes: [NoteListEntry] = []
        for case let url as URL in enumerator {
            if notes.count >= limit { break }
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

    typealias NoteError = NoteSupportError
}
