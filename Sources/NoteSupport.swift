import Foundation

// MARK: - Notes (project-scoped markdown notes at .cmux/notes/<slug>.md)

/// Helpers for the `note` surface type. Notes are plain markdown files stored
/// at `.cmux/notes/<slug>.md` relative to the project root.
enum NoteSupport {
    /// Max slug length. Filenames stay well under any FS limit and remain
    /// comfortably typable.
    static let maxSlugLength = 64

    /// Validate a user-supplied slug. Allowed: lowercase ASCII letters,
    /// digits, hyphens. Must start with a letter or digit. Length 1..=64.
    static func validateSlug(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NoteError.invalidSlug("slug is empty")
        }
        guard trimmed.count <= maxSlugLength else {
            throw NoteError.invalidSlug("slug is longer than \(maxSlugLength) characters")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw NoteError.invalidSlug(
                "slug may contain only lowercase letters, digits, and hyphens"
            )
        }
        guard let first = trimmed.first, first != "-" else {
            throw NoteError.invalidSlug("slug must not start with a hyphen")
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
        do {
            try fs.removeItem(atPath: path)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                return false
            }
            throw error
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
            case .invalidSlug(let reason): return "Invalid note slug: \(reason)"
            case .notRegularFile: return "Note path is not a regular file"
            }
        }

        var errorDescription: String? { description }
    }
}
