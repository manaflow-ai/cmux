import Foundation

extension NotesTreeStorage {
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
    static func isEmptySessionFolder(_ dir: String) -> Bool {
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
}
