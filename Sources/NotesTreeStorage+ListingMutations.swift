import Foundation

extension NotesTreeStorage {
    // MARK: Listing

    /// List the immediate children of `directory`, hiding dotfiles and marker
    /// files. User-created or contentful directories containing a `_session.json`
    /// become session folders; empty auto-discovered session folders stay hidden
    /// so historical sessions do not read as current workspace rows. Other
    /// directories are plain folders; `.md` files are notes; everything else is
    /// omitted. Sorted directories-first, then case-insensitive by name.
    ///
    /// `limit` caps how many entries are materialized (stat + marker reads +
    /// sort), and the streaming enumerator stops reading the directory once the
    /// cap is hit, so a pathologically large directory cannot make the
    /// watcher-driven reload do unbounded work or allocation; callers pass
    /// their remaining node budget. Beyond the cap, selection follows
    /// filesystem order. The scan also bails early when the surrounding reload
    /// task is cancelled (partial results are discarded by the caller's
    /// cancellation guards).
    static func listEntries(inDirectory directory: String, limit: Int = .max) -> [NotesTreeEntry] {
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }
        var entries: [NotesTreeEntry] = []
        for case let url as URL in enumerator {
            if entries.count >= limit || Task.isCancelled { break }
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name == workspaceMarkerName || name == sessionMarkerName { continue }
            // Never traverse symlinks: a project-controlled link under
            // `.cmux/notes` (e.g. `home -> $HOME`) must not let the tree
            // list, open, or watch files outside the notes root. Mutations
            // canonicalize separately; listing is the first boundary.
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true else {
                continue
            }
            let full = (directory as NSString).appendingPathComponent(name)
            if values.isDirectory == true {
                if let marker = sessionMarker(inDirectory: full) {
                    if marker.userCreated != true, isEmptySessionFolder(full) { continue }
                    entries.append(NotesTreeEntry(name: name, path: full, kind: .sessionFolder(marker)))
                } else {
                    entries.append(NotesTreeEntry(name: name, path: full, kind: .folder))
                }
            } else if name.hasSuffix(".md") {
                entries.append(NotesTreeEntry(name: name, path: full, kind: .note))
            }
        }
        return entries.sorted(by: displayOrder)
    }

    /// Display order shared by every level of the tree: plain folders (alpha)
    /// like the Files tree, then notes (alpha), then sessions by recency — the
    /// vault-style strip lives below the file-like content.
    static func displayOrder(_ lhs: NotesTreeEntry, _ rhs: NotesTreeEntry) -> Bool {
        let lRank = displayRank(lhs.kind)
        let rRank = displayRank(rhs.kind)
        if lRank != rRank { return lRank < rRank }
        if let lSession = lhs.kind.sessionMarker, let rSession = rhs.kind.sessionMarker {
            let lModified = lSession.modified ?? 0
            let rModified = rSession.modified ?? 0
            if lModified != rModified { return lModified > rModified }
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func displayRank(_ kind: NotesTreeKind) -> Int {
        switch kind {
        case .folder: return 0
        case .note: return 1
        case .terminalFolder: return 2
        case .sessionFolder: return 3
        case .pastFolder: return 4
        }
    }

    /// Read the `_session.json` marker inside `directory`, if present and valid.
    static func sessionMarker(inDirectory directory: String) -> NotesSessionMarker? {
        let markerPath = (directory as NSString).appendingPathComponent(sessionMarkerName)
        return isSymlink(directory) ? nil : try? readJSON(fromPath: markerPath)
    }

    // MARK: Mutations

    /// Create a new empty note in `folder`. Returns the absolute path. The name
    /// is unique (`untitled.md`, `untitled-2.md`, …).
    @discardableResult
    static func newNote(inFolder folder: String, preferredName: String = "untitled") throws -> String {
        let base = slugify(preferredName, fallback: "untitled")
        let path = uniquePath(inFolder: folder, base: base, ext: "md")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // O_EXCL + O_NOFOLLOW: createFile(atPath:) follows a symlink planted
        // at the new name (a repo can commit `untitled.md -> /elsewhere`), so
        // the leaf must be created exclusively and never through a link —
        // even if one appears between the uniquePath probe and this open.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw NotesTreeStorageError.writeFailed(path)
        }
        close(fd)
        return path
    }

    /// Create a new subfolder in `folder`. Returns the absolute path.
    @discardableResult
    static func newFolder(inFolder folder: String, preferredName: String = "new-folder") throws -> String {
        let base = slugify(preferredName, fallback: "new-folder")
        let path = uniquePath(inFolder: folder, base: base, ext: nil)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return path
    }

    /// Rename `sourcePath` in place (same parent directory). Notes keep their
    /// `.md` extension, names are sanitized for the filesystem, and collisions
    /// are uniquified. Returns the new absolute path (unchanged when the new
    /// name equals the current one).
    @discardableResult
    static func rename(sourcePath: String, toName newName: String) throws -> String {
        let src = standardized(sourcePath)
        let dest = try plannedRenameDestination(sourcePath: sourcePath, toName: newName)
        guard dest != src else { return src }
        try FileManager.default.moveItem(atPath: src, toPath: dest)
        return dest
    }

    static func plannedRenameDestination(sourcePath: String, toName newName: String) throws -> String {
        let fm = FileManager.default
        let src = standardized(sourcePath)
        guard fm.fileExists(atPath: src) else { throw NotesTreeStorageError.sourceMissing(src) }
        let isNote = src.lowercased().hasSuffix(".md")
        guard let stem = sanitizedNameStem(newName, droppingExtension: isNote ? "md" : nil) else {
            throw NotesTreeStorageError.invalidName
        }
        let parent = (src as NSString).deletingLastPathComponent
        let targetName = isNote ? "\(stem).md" : stem
        if targetName == (src as NSString).lastPathComponent { return src }
        // A case-only rename on the (default) case-insensitive filesystem
        // collides with itself in `uniquePath` and would come back suffixed
        // (`Todo-2.md`); rename in place instead.
        if targetName.caseInsensitiveCompare((src as NSString).lastPathComponent) == .orderedSame {
            return (parent as NSString).appendingPathComponent(targetName)
        }
        return uniquePath(inFolder: parent, base: stem, ext: isNote ? "md" : nil)
    }

    /// Filesystem-safe display name: path separators/colons become hyphens,
    /// leading dots are stripped (no hidden files), marker filenames are
    /// rejected. Unlike ``slugify``, spaces and case are preserved — these are
    /// user-chosen names. Returns `nil` when nothing usable remains.
    private static func sanitizedNameStem(_ name: String, droppingExtension ext: String?) -> String? {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ext, trimmed.lowercased().hasSuffix(".\(ext)") {
            trimmed = String(trimmed.dropLast(ext.count + 1))
        }
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stem = String(cleaned.drop(while: { $0 == "." }).prefix(64))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, stem != workspaceMarkerName, stem != sessionMarkerName else { return nil }
        return stem
    }

    /// Move `sourcePath` into `destinationFolder`. Refuses to move a directory
    /// into itself or a descendant, and renames on collision. Returns the new
    /// absolute path.
    @discardableResult
    static func move(sourcePath: String, intoFolder destinationFolder: String) throws -> String {
        let src = standardized(sourcePath)
        let destDir = standardized(destinationFolder)
        let dest = try plannedMoveDestination(sourcePath: sourcePath, intoFolder: destinationFolder)
        guard dest != src else { return src }
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: src, toPath: dest)
        return dest
    }

    static func plannedMoveDestination(sourcePath: String, intoFolder destinationFolder: String) throws -> String {
        let fm = FileManager.default
        let src = standardized(sourcePath)
        let destDir = standardized(destinationFolder)
        guard fm.fileExists(atPath: src) else { throw NotesTreeStorageError.sourceMissing(src) }
        guard isWithin(child: destDir, orEqualTo: src) == false else {
            throw NotesTreeStorageError.invalidMove
        }
        let basename = (src as NSString).lastPathComponent
        // Same-parent no-op move would still collide with itself; short-circuit.
        if (src as NSString).deletingLastPathComponent == destDir { return src }
        let ext = (basename as NSString).pathExtension
        let stem = (basename as NSString).deletingPathExtension
        return uniquePath(inFolder: destDir, base: stem, ext: ext.isEmpty ? nil : ext)
    }
}
