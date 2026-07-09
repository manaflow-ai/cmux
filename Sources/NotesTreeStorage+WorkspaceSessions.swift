import Foundation

extension NotesTreeStorage {
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
}
