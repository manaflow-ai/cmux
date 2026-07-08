import Foundation

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
    private static let markerDataReader = CmuxNoteIndexDataReader(maxBytes: 256 * 1024)

    // MARK: Workspace root resolution

    /// Resolve (without creating) the notes root directory for a workspace.
    /// Preference order: a folder whose marker carries this workspace's
    /// `anchorId`; a legacy folder matching `cwd` that has no anchor yet (it
    /// gets adopted and stamped on the next write); otherwise the path that
    /// *would* be created — keyed by the anchor when present so same-cwd
    /// workspaces never share a folder.
    static func resolveWorkspaceRoot(projectRoot: String, cwd: String, anchorId: String? = nil) -> String {
        let notesDir = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        let normalizedCwd = (cwd as NSString).standardizingPath
        if let existing = existingWorkspaceFolder(inNotesDir: notesDir, cwd: normalizedCwd, anchorId: anchorId) {
            return existing
        }
        return (notesDir as NSString).appendingPathComponent(
            workspaceFolderName(cwd: normalizedCwd, anchorId: anchorId)
        )
    }

    /// Ensure the workspace notes root exists and its `_workspace.json` reflects
    /// the latest `title`/`anchorId`, preserving the accrued session records.
    /// Returns the absolute path to the root.
    @discardableResult
    static func ensureWorkspaceRoot(
        projectRoot: String, cwd: String, title: String, anchorId: String? = nil
    ) throws -> String {
        // A symlinked `.cmux`/`.cmux/notes` would make createDirectory and
        // every tree operation land wherever the link points.
        guard NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) else {
            throw NotesTreeStorageError.untrustedNotesDirectory
        }
        let normalizedCwd = (cwd as NSString).standardizingPath
        let root = resolveWorkspaceRoot(projectRoot: projectRoot, cwd: normalizedCwd, anchorId: anchorId)
        // The resolved folder name is predictable, so a repository can commit
        // it as a symlink; createDirectory would follow it silently and the
        // marker/note writes below would escape the notes tree.
        guard !isSymlink(root) else { throw NotesTreeStorageError.untrustedNotesDirectory }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let markerPath = (root as NSString).appendingPathComponent(workspaceMarkerName)
        let existing: NotesWorkspaceMarker? = try? readJSON(fromPath: markerPath)
        let marker = NotesWorkspaceMarker(
            title: title,
            cwd: normalizedCwd,
            anchorId: anchorId ?? existing?.anchorId,
            sessions: existing?.sessions
        )
        if marker != existing {
            try writeJSON(marker, toPath: markerPath)
        }
        return root
    }

    /// True when the path's own final component is a symbolic link (lstat
    /// semantics; ancestors may still contain system links like `/tmp`).
    static func isSymlink(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    private static func existingWorkspaceFolder(
        inNotesDir notesDir: String, cwd: String, anchorId: String?
    ) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: notesDir) else { return nil }
        var legacyCwdMatch: String?
        for name in names where !name.hasPrefix(".") {
            let dir = (notesDir as NSString).appendingPathComponent(name)
            // Never adopt a symlinked workspace folder: every marker and note
            // write below it would land wherever the link points.
            if isSymlink(dir) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let markerPath = (dir as NSString).appendingPathComponent(workspaceMarkerName)
            guard let marker: NotesWorkspaceMarker = try? readJSON(fromPath: markerPath) else { continue }
            if let anchorId, marker.anchorId == anchorId { return dir }
            if (marker.cwd as NSString).standardizingPath == cwd {
                if anchorId == nil { return dir }
                // Anchor-less marker: adoption candidate for the first
                // anchor-carrying workspace that binds to this cwd.
                if marker.anchorId == nil, legacyCwdMatch == nil { legacyCwdMatch = dir }
            }
        }
        return legacyCwdMatch
    }

    static func workspaceFolderName(cwd: String, anchorId: String? = nil) -> String {
        let base = slugify((cwd as NSString).lastPathComponent, fallback: "workspace")
        let suffix = shortHash(of: anchorId ?? (cwd as NSString).standardizingPath)
        return "\(base)-\(suffix)"
    }

    // MARK: Workspace session records

    /// The session records accrued for this workspace, recency-sorted.
    static func readWorkspaceSessions(inRoot root: String) -> [NotesWorkspaceSessionRecord] {
        guard !isSymlink(root) else { return [] }
        let markerPath = (root as NSString).appendingPathComponent(workspaceMarkerName)
        guard let marker: NotesWorkspaceMarker = try? readJSON(fromPath: markerPath) else { return [] }
        return (marker.sessions ?? []).sorted { $0.modified > $1.modified }
    }

    /// Merge freshly observed pane sessions and live scan results into the
    /// marker's session records: observations upsert (stamping `lastSeen` and
    /// the pane's surface anchor), live entries hydrate titles/recency/cwd for
    /// every record they match. Capped to the most recent `cap` records.
    /// Returns whether the marker changed on disk.
    @discardableResult
    static func updateWorkspaceSessions(
        inRoot root: String,
        observed: [NotesTreeObservedSession],
        live: [NotesSessionDescriptor],
        now: TimeInterval,
        cap: Int = 50
    ) -> Bool {
        guard !isSymlink(root) else { return false }
        let markerPath = (root as NSString).appendingPathComponent(workspaceMarkerName)
        guard let marker: NotesWorkspaceMarker = try? readJSON(fromPath: markerPath) else { return false }
        var byKey: [String: NotesWorkspaceSessionRecord] = [:]
        for record in marker.sessions ?? [] {
            byKey["\(record.agent)\n\(record.sessionId)"] = record
        }
        var liveByKey: [String: NotesSessionDescriptor] = [:]
        for descriptor in live {
            liveByKey["\(descriptor.agent)\n\(descriptor.sessionId)"] = descriptor
        }
        for observation in observed {
            let key = "\(observation.agent)\n\(observation.sessionId)"
            var record = byKey[key] ?? NotesWorkspaceSessionRecord(
                agent: observation.agent,
                sessionId: observation.sessionId,
                surfaceAnchorId: nil,
                title: "",
                cwd: "",
                modified: now,
                lastSeen: now
            )
            // Coarse heartbeat: bumping lastSeen every pass would rewrite the
            // marker on each 10s refresh, firing the folder watcher and
            // reloading the outline — which cancels in-progress drags.
            if now - record.lastSeen > 300 { record.lastSeen = now }
            if let anchor = observation.surfaceAnchorId { record.surfaceAnchorId = anchor }
            byKey[key] = record
        }
        for (key, descriptor) in liveByKey {
            guard var record = byKey[key] else { continue }
            let trimmedTitle = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty { record.title = sanitizedSessionTitle(descriptor.title) }
            if descriptor.modified > record.modified { record.modified = descriptor.modified }
            if !descriptor.cwd.isEmpty { record.cwd = descriptor.cwd }
            byKey[key] = record
        }
        let merged = Array(
            byKey.values
                .sorted { ($0.modified, $0.lastSeen) > ($1.modified, $1.lastSeen) }
                .prefix(cap)
        )
        guard merged != (marker.sessions ?? []) else { return false }
        var updated = marker
        updated.sessions = merged
        do {
            try writeJSON(updated, toPath: markerPath)
            return true
        } catch {
            return false
        }
    }

    // MARK: Flat (index.json) notes

    /// The flat notes belonging to one workspace: `.cmux/notes/index.json`
    /// records carrying an attachment to `workspaceAnchorId`, resolved to
    /// display title + absolute body path. Records whose body file is missing
    /// (e.g. deleted from the tree) are skipped. Notes from other workspaces
    /// never appear.
    static func listIndexedNotes(projectRoot: String, workspaceAnchorId: String) -> [NotesFlatNoteRef] {
        guard let records = try? CmuxNoteStore.list(projectRoot: projectRoot) else { return [] }
        let fm = FileManager.default
        var refs: [NotesFlatNoteRef] = []
        for record in records {
            let attachments = record.attachments.filter { $0.workspaceAnchorId == workspaceAnchorId }
            guard !attachments.isEmpty else { continue }
            let path = CmuxNoteStore.noteBodyPath(for: record, projectRoot: projectRoot)
            guard fm.fileExists(atPath: path) else { continue }
            let trimmedTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            refs.append(NotesFlatNoteRef(
                title: trimmedTitle.isEmpty ? record.slug : record.title,
                path: path,
                surfaceAnchorId: attachments.compactMap(\.surfaceAnchorId).first
            ))
        }
        return refs
    }

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
        let recentKeys = Set(sorted.prefix(recentLimit).map { sessionKey(agent: $0.agent, sessionId: $0.sessionId) })

        // Index existing session folders, pruning empty ones outside the recent
        // window (they hold no notes, so removal is lossless).
        var folderForSession: [String: String] = [:]
        if let names = try? fm.contentsOfDirectory(atPath: root) {
            for name in names where !name.hasPrefix(".") {
                let dir = (root as NSString).appendingPathComponent(name)
                guard !isSymlink(dir), let marker = sessionMarker(inDirectory: dir) else { continue }
                let key = sessionKey(agent: marker.agent, sessionId: marker.sessionId)
                if marker.userCreated != true, !recentKeys.contains(key), isEmptySessionFolder(dir) {
                    try? fm.removeItem(atPath: dir)
                    continue
                }
                folderForSession[key] = dir
            }
        }

        for descriptor in sorted {
            let key = sessionKey(agent: descriptor.agent, sessionId: descriptor.sessionId)
            let dir: String
            if let existing = folderForSession[key] {
                dir = existing
            } else if recentKeys.contains(key) {
                let name = sessionFolderName(descriptor: descriptor)
                dir = uniquePath(inFolder: root, base: name, ext: nil)
                guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { continue }
                folderForSession[key] = dir
            } else {
                continue  // Older session with no notes — don't materialize.
            }
            let marker = NotesSessionMarker(
                agent: descriptor.agent,
                sessionId: descriptor.sessionId,
                cwd: descriptor.cwd,
                title: descriptor.title,
                modified: descriptor.modified,
                userCreated: sessionMarker(inDirectory: dir)?.userCreated
            )
            // Only rewrite the marker when it actually changed; rewriting it on
            // every sync would bump the file's mtime and storm the per-folder
            // file watchers (the source of the Notes-tab lag).
            if sessionMarker(inDirectory: dir) != marker {
                try? writeJSON(marker, toPath: (dir as NSString).appendingPathComponent(sessionMarkerName))
            }
        }
    }

    /// True when `dir` contains EXACTLY the generated `_session.json` marker
    /// and nothing else. The Notes tree is a user-editable filesystem, so any
    /// other content — including dotfiles like `.env` or `.keep` — makes the
    /// folder user-owned and exempt from the automatic prune (which deletes
    /// permanently, not to Trash).
    private static func isEmptySessionFolder(_ dir: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        // .DS_Store is Finder metadata, never user content; anything else
        // keeps the folder.
        return names.allSatisfy { $0 == sessionMarkerName || $0 == ".DS_Store" }
    }

    static func sessionFolderName(descriptor: NotesSessionDescriptor) -> String {
        let base = slugify(descriptor.title, fallback: "session")
        let suffix = shortSuffix(of: descriptor.sessionId)
        return suffix.isEmpty ? base : "\(base)-\(suffix)"
    }

    /// Create (or reuse) a session folder for `descriptor` inside `folder`,
    /// idempotent on agent + session id. Used when a session is dragged into
    /// the tree (from the Vault or another Notes session); sessions are
    /// user-curated, not auto-materialized. Returns the folder path.
    @discardableResult
    static func createSessionFolder(inFolder folder: String, descriptor: NotesSessionDescriptor) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if let existing = existingSessionFolder(
            inFolder: folder, agent: descriptor.agent, sessionId: descriptor.sessionId
        ) {
            let marker = NotesSessionMarker(
                agent: descriptor.agent,
                sessionId: descriptor.sessionId,
                cwd: descriptor.cwd,
                title: descriptor.title,
                modified: descriptor.modified,
                userCreated: true
            )
            if sessionMarker(inDirectory: existing) != marker {
                try? writeJSON(marker, toPath: (existing as NSString).appendingPathComponent(sessionMarkerName))
            }
            return existing
        }
        let name = sessionFolderName(descriptor: descriptor)
        let dir = uniquePath(inFolder: folder, base: name, ext: nil)
        guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let marker = NotesSessionMarker(
            agent: descriptor.agent,
            sessionId: descriptor.sessionId,
            cwd: descriptor.cwd,
            title: descriptor.title,
            modified: descriptor.modified,
            userCreated: true
        )
        try? writeJSON(marker, toPath: (dir as NSString).appendingPathComponent(sessionMarkerName))
        return dir
    }

    /// Find an existing session folder for `agent` + `sessionId` directly inside `folder`.
    private static func existingSessionFolder(inFolder folder: String, agent: String, sessionId: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        for name in names where !name.hasPrefix(".") {
            let dir = (folder as NSString).appendingPathComponent(name)
            if !isSymlink(dir), let marker = sessionMarker(inDirectory: dir),
               marker.agent == agent,
               marker.sessionId == sessionId {
                return dir
            }
        }
        return nil
    }

    private static func sessionKey(agent: String, sessionId: String) -> String {
        "\(agent)\n\(sessionId)"
    }

    // MARK: Session marker refresh

    /// Every session folder anywhere under `root`, with its current marker.
    /// Depth-capped like the tree build so a pathological hierarchy can't hang
    /// the refresh walk.
    /// Walk budget for the live-refresh session scan. This runs on the
    /// visible-sidebar refresh cadence, so the traversal is bounded the same
    /// way the tree build is — a huge or imported notes tree costs at most
    /// `directoryBudget` directory listings and `maxSessions` collected
    /// markers per pass instead of unbounded recursion.
    static func collectSessionFolders(
        inRoot root: String,
        maxDepth: Int = 12,
        directoryBudget: Int = 2000,
        maxSessions: Int = 200
    ) -> [NotesSessionFolderRef] {
        guard !isSymlink(root) else { return [] }
        var found: [NotesSessionFolderRef] = []
        var remainingDirectories = directoryBudget
        func walk(_ directory: String, depth: Int) {
            guard depth < maxDepth, remainingDirectories > 0, found.count < maxSessions else { return }
            remainingDirectories -= 1
            // Cap each listing at the remaining directory budget: more entries
            // than that can't all be visited, and an unbounded listing would
            // let one huge directory dominate every 10s visible refresh.
            for entry in listEntries(inDirectory: directory, limit: remainingDirectories + 1) where entry.kind.isDirectory {
                if let marker = entry.kind.sessionMarker {
                    found.append(NotesSessionFolderRef(directory: entry.path, marker: marker))
                    if found.count >= maxSessions { return }
                }
                walk(entry.path, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return found
    }

    /// Session titles come from transcript content and can be huge multiline
    /// pastes; rows are single-line, so collapse whitespace and cap length at
    /// the storage boundary.
    static func sanitizedSessionTitle(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(160))
    }

    /// Rewrite the markers in `folders` whose session has drifted from the
    /// matching `live` entry (keyed by agent + sessionId): newer `modified`,
    /// changed title, or changed cwd. Folders with no live match (deleted or
    /// foreign sessions) are left untouched — they may hold notes. Returns
    /// whether any marker file was rewritten, so callers reload only when
    /// something actually changed (rewrites bump mtimes and fire the watchers).
    @discardableResult
    static func applySessionRefresh(
        folders: [NotesSessionFolderRef],
        live: [NotesSessionDescriptor]
    ) -> Bool {
        var liveByKey: [String: NotesSessionDescriptor] = [:]
        for descriptor in live {
            liveByKey["\(descriptor.agent)\n\(descriptor.sessionId)"] = descriptor
        }
        var changed = false
        for folder in folders {
            guard let liveEntry = liveByKey["\(folder.marker.agent)\n\(folder.marker.sessionId)"] else { continue }
            var updated = folder.marker
            if !liveEntry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.title = sanitizedSessionTitle(liveEntry.title)
            }
            if liveEntry.modified > (updated.modified ?? 0) {
                updated.modified = liveEntry.modified
            }
            if !liveEntry.cwd.isEmpty {
                updated.cwd = liveEntry.cwd
            }
            guard updated != folder.marker else { continue }
            do {
                try writeJSON(updated, toPath: (folder.directory as NSString).appendingPathComponent(sessionMarkerName))
                changed = true
            } catch {
                continue
            }
        }
        return changed
    }

    // MARK: - Helpers

    /// True when `child` is equal to, or nested inside, `ancestor`.
    /// Containment check used by every tree mutation guard. Canonicalizes
    /// both sides (symlinks resolved) so a linked directory placed inside the
    /// tree — e.g. `.cmux/notes/<ws>/out -> ~/target` — can never authorize
    /// writes outside the notes root. Missing path suffixes resolve lexically,
    /// so not-yet-created roots still compare correctly.
    static func isWithin(child: String, orEqualTo ancestor: String) -> Bool {
        let c = canonicalized(child)
        let a = canonicalized(ancestor)
        return c == a || c.hasPrefix(a + "/")
    }

    private static func canonicalized(_ path: String) -> String {
        ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
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
        // fileExists follows symlinks, so a project-controlled BROKEN link at
        // the candidate name would read as free; lstat (isSymlink) treats any
        // link as occupied so creation never lands on one.
        while fm.fileExists(atPath: candidate) || isSymlink(candidate) {
            candidate = compose("\(base)-\(counter)")
            counter += 1
        }
        return candidate
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
        guard let data = try markerDataReader.readIfPresent(atPath: path) else {
            throw POSIXError(.ENOENT)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
