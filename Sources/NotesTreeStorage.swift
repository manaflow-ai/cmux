import Foundation

// MARK: - Marker files

/// Contents of a per-workspace `_workspace.json` marker. The notes folder is
/// keyed by the workspace's `cwd` (its working directory) — a stable identity
/// that survives app restarts, unlike the ephemeral per-instance note anchor —
/// so a workspace always rebinds to the same folder instead of orphaning notes.
struct NotesWorkspaceMarker: Codable, Equatable, Sendable {
    /// Human-friendly workspace title, kept fresh for display/browsing.
    var title: String
    /// The workspace's working directory (standardized); the binding key.
    var cwd: String
}

/// Contents of a `_session.json` marker inside a session folder. Drives the
/// folder's session icon and the Resume action.
struct NotesSessionMarker: Codable, Equatable, Sendable {
    /// Agent identifier; currently always `"claude"`.
    var agent: String
    /// The agent's native session id (passed to `claude --resume <id>`).
    var sessionId: String
    /// The session's working directory.
    var cwd: String
    /// Display title for the session.
    var title: String
    /// Last-modified time of the session (Unix seconds); drives the relative
    /// timestamp and recency sort. Optional for backward-compatible decoding of
    /// markers written before this field existed.
    var modified: TimeInterval?
}

/// A Claude session discovered for a workspace, used to materialize/refresh
/// session folders. Produced by the app from `SessionIndexStore` and handed to
/// ``NotesTreeStorage/syncSessionFolders(inRoot:descriptors:)``.
struct NotesSessionDescriptor: Equatable, Sendable {
    var agent: String
    var sessionId: String
    var title: String
    var cwd: String
    /// Session last-modified time (Unix seconds), for the relative timestamp.
    var modified: TimeInterval
}

/// One immediate child of a directory in the Notes tree (pre-node value type).
struct NotesTreeEntry: Equatable, Sendable {
    let name: String
    let path: String
    let kind: NotesTreeKind
}

// MARK: - Storage

/// Filesystem owner for the per-workspace Notes tree.
///
/// The tree is a real directory hierarchy rooted at
/// `<projectRoot>/.cmux/notes/<workspace-folder>/`. The filesystem is the source
/// of truth: notes are plain `.md` files, "moving" a note is a real
/// `FileManager` move, and session folders are real directories tagged by a
/// `_session.json` marker. This type performs no UI work and holds no state,
/// mirroring the app-target convention of ``NoteSupport``/``CmuxNoteStore``.
enum NotesTreeStorage {
    /// Marker filename binding a folder to a workspace.
    static let workspaceMarkerName = "_workspace.json"
    /// Marker filename tagging a directory as a Claude session folder.
    static let sessionMarkerName = "_session.json"

    // MARK: Workspace root resolution

    /// Resolve (without creating) the notes root directory for a workspace,
    /// keyed by its `cwd`. Prefers an existing folder whose `_workspace.json.cwd`
    /// matches; otherwise returns the path it *would* create from the cwd's
    /// basename plus a short stable hash of the full cwd.
    static func resolveWorkspaceRoot(projectRoot: String, cwd: String) -> String {
        let notesDir = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        let normalizedCwd = (cwd as NSString).standardizingPath
        if let existing = existingWorkspaceFolder(inNotesDir: notesDir, cwd: normalizedCwd) {
            return existing
        }
        return (notesDir as NSString).appendingPathComponent(workspaceFolderName(cwd: normalizedCwd))
    }

    /// Ensure the workspace notes root exists and its `_workspace.json` reflects
    /// the latest `title`. Returns the absolute path to the root.
    @discardableResult
    static func ensureWorkspaceRoot(projectRoot: String, cwd: String, title: String) throws -> String {
        let normalizedCwd = (cwd as NSString).standardizingPath
        let root = resolveWorkspaceRoot(projectRoot: projectRoot, cwd: normalizedCwd)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let marker = NotesWorkspaceMarker(title: title, cwd: normalizedCwd)
        try writeJSON(marker, toPath: (root as NSString).appendingPathComponent(workspaceMarkerName))
        return root
    }

    private static func existingWorkspaceFolder(inNotesDir notesDir: String, cwd: String) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: notesDir) else { return nil }
        for name in names where !name.hasPrefix(".") {
            let dir = (notesDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let markerPath = (dir as NSString).appendingPathComponent(workspaceMarkerName)
            guard let marker: NotesWorkspaceMarker = try? readJSON(fromPath: markerPath) else { continue }
            if (marker.cwd as NSString).standardizingPath == cwd { return dir }
        }
        return nil
    }

    static func workspaceFolderName(cwd: String) -> String {
        let base = slugify((cwd as NSString).lastPathComponent, fallback: "workspace")
        let suffix = shortHash(of: (cwd as NSString).standardizingPath)
        return "\(base)-\(suffix)"
    }

    // MARK: Listing

    /// List the immediate children of `directory`, hiding dotfiles and marker
    /// files. Directories containing a `_session.json` become session folders;
    /// other directories are plain folders; `.md` files are notes; everything
    /// else is omitted. Sorted directories-first, then case-insensitive by name.
    static func listEntries(inDirectory directory: String) -> [NotesTreeEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var entries: [NotesTreeEntry] = []
        for name in names {
            if name.hasPrefix(".") || name == workspaceMarkerName || name == sessionMarkerName { continue }
            let full = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let marker = sessionMarker(inDirectory: full) {
                    entries.append(NotesTreeEntry(name: name, path: full, kind: .sessionFolder(marker)))
                } else {
                    entries.append(NotesTreeEntry(name: name, path: full, kind: .folder))
                }
            } else if name.hasSuffix(".md") {
                entries.append(NotesTreeEntry(name: name, path: full, kind: .note))
            }
        }
        return entries.sorted { lhs, rhs in
            // Directories first; plain folders (alpha) above session folders;
            // session folders by recency (most recent first); notes alpha.
            if lhs.kind.isDirectory != rhs.kind.isDirectory { return lhs.kind.isDirectory }
            let lSession = lhs.kind.sessionMarker
            let rSession = rhs.kind.sessionMarker
            if (lSession == nil) != (rSession == nil) { return lSession == nil }
            if let lSession, let rSession {
                let lModified = lSession.modified ?? 0
                let rModified = rSession.modified ?? 0
                if lModified != rModified { return lModified > rModified }
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Read the `_session.json` marker inside `directory`, if present and valid.
    static func sessionMarker(inDirectory directory: String) -> NotesSessionMarker? {
        let markerPath = (directory as NSString).appendingPathComponent(sessionMarkerName)
        return try? readJSON(fromPath: markerPath)
    }

    // MARK: Mutations

    /// Create a new empty note in `folder`. Returns the absolute path. The name
    /// is unique (`untitled.md`, `untitled-2.md`, …).
    @discardableResult
    static func newNote(inFolder folder: String, preferredName: String = "untitled") throws -> String {
        let base = slugify(preferredName, fallback: "untitled")
        let path = uniquePath(inFolder: folder, base: base, ext: "md")
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard fm.createFile(atPath: path, contents: Data()) else {
            throw NotesTreeStorageError.writeFailed(path)
        }
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

    /// Move `sourcePath` into `destinationFolder`. Refuses to move a directory
    /// into itself or a descendant, and renames on collision. Returns the new
    /// absolute path.
    @discardableResult
    static func move(sourcePath: String, intoFolder destinationFolder: String) throws -> String {
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
        let dest = uniquePath(inFolder: destDir, base: stem, ext: ext.isEmpty ? nil : ext)
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        try fm.moveItem(atPath: src, toPath: dest)
        return dest
    }

    // MARK: Session-folder sync

    /// Materialize session folders for the most-recent sessions and refresh
    /// their `_session.json`. Folders that contain notes are always kept and
    /// refreshed; **empty** (note-less) session folders outside the recent
    /// window are pruned so the tree isn't flooded by every historical session.
    /// Idempotent.
    static func syncSessionFolders(inRoot root: String, descriptors: [NotesSessionDescriptor]) {
        let fm = FileManager.default
        guard (try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)) != nil else { return }
        let recentLimit = 30
        let sorted = descriptors.sorted { $0.modified > $1.modified }
        let recentIds = Set(sorted.prefix(recentLimit).map(\.sessionId))

        // Index existing session folders, pruning empty ones outside the recent
        // window (they hold no notes, so removal is lossless).
        var folderForSession: [String: String] = [:]
        if let names = try? fm.contentsOfDirectory(atPath: root) {
            for name in names where !name.hasPrefix(".") {
                let dir = (root as NSString).appendingPathComponent(name)
                guard let marker = sessionMarker(inDirectory: dir) else { continue }
                if !recentIds.contains(marker.sessionId), isEmptySessionFolder(dir) {
                    try? fm.removeItem(atPath: dir)
                    continue
                }
                folderForSession[marker.sessionId] = dir
            }
        }

        for descriptor in sorted {
            let marker = NotesSessionMarker(
                agent: descriptor.agent,
                sessionId: descriptor.sessionId,
                cwd: descriptor.cwd,
                title: descriptor.title,
                modified: descriptor.modified
            )
            let dir: String
            if let existing = folderForSession[descriptor.sessionId] {
                dir = existing
            } else if recentIds.contains(descriptor.sessionId) {
                let name = sessionFolderName(descriptor: descriptor)
                dir = uniquePath(inFolder: root, base: name, ext: nil)
                guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { continue }
                folderForSession[descriptor.sessionId] = dir
            } else {
                continue  // Older session with no notes — don't materialize.
            }
            // Only rewrite the marker when it actually changed; rewriting it on
            // every sync would bump the file's mtime and storm the per-folder
            // file watchers (the source of the Notes-tab lag).
            if sessionMarker(inDirectory: dir) != marker {
                try? writeJSON(marker, toPath: (dir as NSString).appendingPathComponent(sessionMarkerName))
            }
        }
    }

    /// True when `dir` is a session folder holding no notes — only its
    /// `_session.json` marker (and possibly dotfiles). Such folders are safe to
    /// prune since they contain no user content.
    private static func isEmptySessionFolder(_ dir: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return names.allSatisfy { $0 == sessionMarkerName || $0.hasPrefix(".") }
    }

    static func sessionFolderName(descriptor: NotesSessionDescriptor) -> String {
        let base = slugify(descriptor.title, fallback: "session")
        let suffix = shortSuffix(of: descriptor.sessionId)
        return suffix.isEmpty ? base : "\(base)-\(suffix)"
    }

    // MARK: - Helpers

    /// True when `child` is equal to, or nested inside, `ancestor`.
    static func isWithin(child: String, orEqualTo ancestor: String) -> Bool {
        let c = standardized(child)
        let a = standardized(ancestor)
        return c == a || c.hasPrefix(a + "/")
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func uniquePath(inFolder folder: String, base: String, ext: String?) -> String {
        let fm = FileManager.default
        func compose(_ stem: String) -> String {
            let name = (ext?.isEmpty == false) ? "\(stem).\(ext!)" : stem
            return (folder as NSString).appendingPathComponent(name)
        }
        var candidate = compose(base)
        var counter = 2
        while fm.fileExists(atPath: candidate) {
            candidate = compose("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }

    /// Lowercase, hyphen-joined slug of `value`; `fallback` when empty.
    static func slugify(_ value: String, fallback: String) -> String {
        let lowered = value.lowercased()
        var out = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let capped = String(trimmed.prefix(48))
        return capped.isEmpty ? fallback : capped
    }

    /// First 6 alphanumerics from the tail of an id (session), for a short,
    /// stable, collision-resistant folder suffix.
    private static func shortSuffix(of id: String) -> String {
        let alnum = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(alnum.suffix(6))).lowercased()
    }

    /// Deterministic 6-hex FNV-1a hash of `value`, so the same cwd always maps to
    /// the same workspace folder suffix across app restarts.
    private static func shortHash(of value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(hex.suffix(6))
    }

    private static func writeJSON<T: Encodable>(_ value: T, toPath path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private static func readJSON<T: Decodable>(fromPath path: String) throws -> T {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Errors thrown by ``NotesTreeStorage`` mutations.
enum NotesTreeStorageError: Error, LocalizedError {
    case sourceMissing(String)
    case invalidMove
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return String(
                format: String(localized: "notes.error.sourceMissing", defaultValue: "Note no longer exists: %@"),
                locale: .current,
                path
            )
        case .invalidMove:
            return String(localized: "notes.error.invalidMove", defaultValue: "Cannot move a folder into itself")
        case .writeFailed(let path):
            return String(
                format: String(localized: "notes.error.writeFailed", defaultValue: "Could not create note: %@"),
                locale: .current,
                path
            )
        }
    }
}
