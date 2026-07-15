import Foundation

extension NotesTreeStore {
    // MARK: - Mutations

    func currentRootIsTrusted(_ root: String) -> Bool {
        if let projectRoot,
           !NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) {
            return false
        }
        return !NotesTreeStorage.isSymlink(root)
    }

    func clearRenderedRootIfCurrent(_ root: String) {
        guard resolvedRootPath == root else { return }
        clearRenderedRoot()
    }

    func clearRenderedRoot() {
        rootNodes = []
        contentRevision &+= 1
    }

    @discardableResult
    func updateObservedSessionKeys(sessions: [NotesTreeObservedSession]) -> Bool {
        let next = Set(sessions.map { Self.sessionKey(agent: $0.agent, sessionId: $0.sessionId) })
        guard next != observedSessionKeys || sessions != observedSessions else { return false }
        observedSessionKeys = next
        observedSessions = sessions
        return true
    }

    static func sessionKey(agent: String, sessionId: String) -> String {
        "\(agent)\n\(sessionId)"
    }

    static func terminalActiveSessions(
        records: [NotesWorkspaceSessionRecord],
        observations: [NotesTreeObservedSession]
    ) -> [String: NotesSessionMarker] {
        var recordByKey: [String: NotesWorkspaceSessionRecord] = [:]
        for record in records {
            recordByKey[Self.sessionKey(agent: record.agent, sessionId: record.sessionId)] = record
        }
        var active: [String: NotesSessionMarker] = [:]
        for observation in observations {
            let key = Self.sessionKey(agent: observation.agent, sessionId: observation.sessionId)
            let record = recordByKey[key]
            let marker = NotesSessionMarker(
                agent: record?.agent ?? observation.agent,
                sessionId: record?.sessionId ?? observation.sessionId,
                cwd: record?.cwd ?? "",
                title: record?.title ?? "",
                modified: record?.modified,
                userCreated: nil
            )
            if let panelId = observation.terminalPanelId, active[panelId] == nil {
                active[panelId] = marker
            }
            if let anchor = observation.surfaceAnchorId, active[anchor] == nil {
                active[anchor] = marker
            }
        }
        return active
    }

    /// Create a new empty note in `folder` (or the workspace root if nil).
    @discardableResult
    func newNote(inFolder folder: String? = nil) -> String? {
        guard let target = try? ensureRoot(folder: folder) else { return nil }
        let path = try? NotesTreeStorage.newNote(inFolder: target)
        if let path { reflectCreatedPath(path, kind: .note) }
        reload()
        return path
    }

    /// Create a new subfolder in `folder` (or the workspace root if nil).
    @discardableResult
    func newFolder(inFolder folder: String? = nil) -> String? {
        guard let target = try? ensureRoot(folder: folder) else { return nil }
        let path = try? NotesTreeStorage.newFolder(inFolder: target)
        if let path { reflectCreatedPath(path, kind: .folder) }
        reload()
        return path
    }

    private func reflectCreatedPath(_ path: String, kind: NotesTreeKind) {
        guard let root = resolvedRootPath else { return }
        let standardizedRoot = (root as NSString).standardizingPath
        let standardizedPath = (path as NSString).standardizingPath
        guard NotesTreeStorage.isWithin(child: standardizedPath, orEqualTo: standardizedRoot) else {
            return
        }
        let parentPath = (standardizedPath as NSString).deletingLastPathComponent
        let node = NotesTreeNode(
            name: (standardizedPath as NSString).lastPathComponent,
            path: standardizedPath,
            kind: kind,
            children: kind.isDirectory ? [] : nil
        )

        if parentPath == standardizedRoot {
            Self.upsertCreatedNode(node, into: &rootNodes)
            contentRevision &+= 1
            return
        }
        guard let parent = Self.findNode(path: parentPath, in: rootNodes),
              parent.kind.isDirectory else { return }
        var children = parent.children ?? []
        Self.upsertCreatedNode(node, into: &children)
        parent.children = children
        contentRevision &+= 1
    }

    private static func upsertCreatedNode(_ node: NotesTreeNode, into nodes: inout [NotesTreeNode]) {
        if let index = nodes.firstIndex(where: { $0.path == node.path }) {
            nodes[index] = node
        } else {
            nodes.append(node)
        }
        nodes.sort(by: nodeDisplayOrder)
    }

    private static func findNode(path: String, in nodes: [NotesTreeNode]) -> NotesTreeNode? {
        let target = (path as NSString).standardizingPath
        for node in nodes {
            if (node.path as NSString).standardizingPath == target {
                return node
            }
            if let children = node.children,
               let match = findNode(path: target, in: children) {
                return match
            }
        }
        return nil
    }

    /// Rename a note/folder in place. Confined to the project's `.cmux/notes`
    /// directory (which covers both the workspace subtree and the flat notes
    /// at its root). Carries the collapsed-state of the renamed subtree over
    /// to its new path so a rename doesn't visually re-expand everything
    /// beneath it. Returns the new path, or nil when the rename was rejected.
    @discardableResult
    func rename(path: String, toName newName: String) -> String? {
        guard isMutablePath(path) else { return nil }
        let oldPrefix = (path as NSString).standardizingPath
        guard let renamed = try? NotesTreeStorage.plannedRenameDestination(
            sourcePath: oldPrefix,
            toName: newName
        ) else {
            reload()
            return nil
        }
        let newPrefix = (renamed as NSString).standardizingPath
        do {
            if oldPrefix != newPrefix {
                try rebaseIndexedBodies(from: oldPrefix, to: newPrefix)
                do {
                    try FileManager.default.moveItem(atPath: oldPrefix, toPath: newPrefix)
                } catch {
                    try? rebaseIndexedBodies(from: newPrefix, to: oldPrefix)
                    throw error
                }
            }
        } catch {
            reload()
            return nil
        }
        if oldPrefix != newPrefix {
            collapsedPaths = Set(collapsedPaths.map { collapsed in
                if collapsed == oldPrefix { return newPrefix }
                if collapsed.hasPrefix(oldPrefix + "/") {
                    return newPrefix + collapsed.dropFirst(oldPrefix.count)
                }
                return collapsed
            })
        }
        postRelocation(from: oldPrefix, to: newPrefix)
        reload()
        return renamed
    }

    /// Move an index-owned flat note into `destinationFolder` through the flat
    /// store, which relocates the body AND rewrites the index's bodyPath in
    /// one transaction (a bare file move would orphan the record). Returns the
    /// new path.
    @discardableResult
    func moveFlatNote(path: String, intoFolder destinationFolder: String) -> String? {
        guard let projectRoot,
              let notesDir = notesDirPath,
              NotesTreeStorage.isWithin(child: destinationFolder, orEqualTo: notesDir),
              let record = indexedNoteRecord(path: path) else { return nil }
        let moved = try? CmuxNoteStore.relocateBody(
            slug: record.slug, projectRoot: projectRoot, toDirectory: destinationFolder
        )
        if let moved {
            if let workspaceAnchorId {
                _ = try? CmuxNoteStore.attachBodyPath(
                    moved,
                    projectRoot: projectRoot,
                    to: .workspace(workspaceAnchorId: workspaceAnchorId)
                )
            }
            postRelocation(from: path, to: moved)
        }
        reload()
        return moved
    }

    /// File a note under a terminal virtual row. Terminal rows are not real
    /// directories, so the note becomes an indexed flat note attached to that
    /// terminal's surface anchor; if the body currently lives inside the
    /// workspace tree, move it back to the flat notes directory so it no
    /// longer appears in its old filesystem location.
    @discardableResult
    func attachNote(
        path: String,
        toTerminal terminal: NotesTreeObservedTerminal,
        target: CmuxNoteAttachmentTarget
    ) -> String? {
        guard let projectRoot,
              let notesDir = notesDirPath,
              let root = resolvedRootPath,
              isMutablePath(path) else { return nil }
        let surfaceAnchorId: String
        switch target {
        case .surface(let workspaceAnchorId, let anchorId, let surfaceKind)
            where workspaceAnchorId == self.workspaceAnchorId && surfaceKind == PanelType.terminal.rawValue:
            surfaceAnchorId = anchorId
        default:
            return nil
        }

        if let index = observedTerminals.firstIndex(where: { $0.panelId == terminal.panelId }),
           observedTerminals[index].anchorId != surfaceAnchorId {
            observedTerminals[index].anchorId = surfaceAnchorId
        }

        guard let attached = try? CmuxNoteStore.attachBodyPath(
            path,
            projectRoot: projectRoot,
            to: target
        ) else {
            reload()
            return nil
        }

        var bodyPath = CmuxNoteStore.noteBodyPath(for: attached, projectRoot: projectRoot)
        if NotesTreeStorage.isWithin(child: bodyPath, orEqualTo: root),
           let relocated = try? CmuxNoteStore.relocateBody(
                slug: attached.slug,
                projectRoot: projectRoot,
                toDirectory: notesDir
           ) {
            postRelocation(from: bodyPath, to: relocated)
            bodyPath = relocated
        }
        reload()
        return bodyPath
    }

    /// Rename an index-owned flat note by retitling its index record — the
    /// record title is what the tree displays for these notes, and their body
    /// path is pinned by `index.json`, so no file moves. Returns the
    /// (unchanged) body path on success, nil when the path has no index
    /// record. A whitespace-only title keeps the current one.
    @discardableResult
    func renameFlatNote(path: String, toTitle newTitle: String) -> String? {
        guard let projectRoot else { return nil }
        let target = (path as NSString).standardizingPath
        guard let record = indexedNoteRecord(path: path) else { return nil }
        guard let retitled = try? CmuxNoteStore.retitle(
            slug: record.slug, projectRoot: projectRoot, title: newTitle
        ) else {
            reload()
            return nil
        }
        // Open panels on this note show the record title in their tab; let
        // them adopt the new one (the body path is unchanged, so the
        // relocation notification doesn't cover renames of flat notes).
        NotificationCenter.default.post(
            name: .cmuxNoteRetitled,
            object: nil,
            userInfo: ["bodyPath": target, "title": retitled.title]
        )
        reload()
        return target
    }

    /// Delete an index-owned flat note through the tree UI: remove the index
    /// record, move the body to Trash, and restore the record if Trash fails.
    /// Trashing only the body file would leave `cmux note list` showing a note
    /// whose `read` fails.
    func deleteFlatNote(path: String) {
        guard let projectRoot,
              indexedNoteRecord(path: path) != nil else {
            reload()
            return
        }
        let target = (path as NSString).standardizingPath
        let removedRecords: [CmuxNoteRecord]
        do {
            removedRecords = try CmuxNoteStore.removeRecords(
                underAbsolutePath: target,
                projectRoot: projectRoot
            )
        } catch {
            reload()
            return
        }
        guard !removedRecords.isEmpty else {
            reload()
            return
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
        } catch {
            try? CmuxNoteStore.restoreRecords(removedRecords, projectRoot: projectRoot)
            reload()
            return
        }
        reload()
    }

    func isIndexedNote(path: String) -> Bool {
        indexedNoteRecord(path: path) != nil
    }

    private func indexedNoteRecord(path: String) -> CmuxNoteRecord? {
        guard let projectRoot,
              let records = try? CmuxNoteStore.list(projectRoot: projectRoot) else { return nil }
        let target = (path as NSString).standardizingPath
        return records.first {
            (CmuxNoteStore.noteBodyPath(for: $0, projectRoot: projectRoot) as NSString)
                .standardizingPath == target
        }
    }

    /// A path the tree may rename/delete: inside `.cmux/notes`, but never the
    /// notes directory itself nor the workspace's own root folder.
    func isMutablePath(_ path: String) -> Bool {
        if let projectRoot, !NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) {
            return false
        }
        guard let notesDir = notesDirPath,
              NotesTreeStorage.isWithin(child: path, orEqualTo: notesDir) else { return false }
        let standardized = (path as NSString).standardizingPath
        if standardized == (notesDir as NSString).standardizingPath { return false }
        if let root = resolvedRootPath, standardized == (root as NSString).standardizingPath { return false }
        if Self.containsProtectedNotesComponent(path: standardized, notesDir: notesDir) { return false }
        return true
    }

    private static func containsProtectedNotesComponent(path: String, notesDir: String) -> Bool {
        let root = (notesDir as NSString).standardizingPath
        guard path.hasPrefix(root + "/") else { return false }
        let relative = path.dropFirst(root.count + 1)
        return relative.split(separator: "/").contains { component in
            let name = String(component)
            return name.hasPrefix(".") ||
                name == "index.json" ||
                name == NotesTreeStorage.workspaceMarkerName ||
                name == NotesTreeStorage.sessionMarkerName
        }
    }

    /// Ensure the workspace root exists and return the mutation target directory.
    /// `folder` (when given) must lie within the workspace root.
    func ensureRoot(folder: String?) throws -> String {
        guard let projectRoot, let cwd else {
            throw NotesTreeStorageError.invalidMove
        }
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: cwd, title: workspaceTitle, anchorId: workspaceAnchorId
        )
        resolvedRootPath = root
        guard let folder else { return root }
        // Fail closed on a stale or foreign destination: silently retargeting
        // the mutation at the workspace root would create or move items in the
        // wrong place. Callers surface this as a nil/no-op result.
        guard NotesTreeStorage.isWithin(child: folder, orEqualTo: root) else {
            throw NotesTreeStorageError.invalidMove
        }
        return folder
    }
}
