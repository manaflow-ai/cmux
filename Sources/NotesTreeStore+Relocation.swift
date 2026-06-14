import Foundation

extension NotesTreeStore {
    /// Move a note/folder into `destinationFolder`. Returns the new path, or nil
    /// on failure (e.g. invalid move). Both endpoints must lie inside
    /// `.cmux/notes`: the move pasteboard type is globally forgeable, so a
    /// crafted drag payload must never be able to relocate arbitrary
    /// user-writable files into (or around) the project.
    @discardableResult
    func move(sourcePath: String, intoFolder destinationFolder: String) -> String? {
        guard isMutablePath(sourcePath),
              let notesDir = notesDirPath,
              NotesTreeStorage.isWithin(child: destinationFolder, orEqualTo: notesDir)
        else { return nil }
        let source = (sourcePath as NSString).standardizingPath
        guard let moved = try? NotesTreeStorage.plannedMoveDestination(
            sourcePath: source,
            intoFolder: destinationFolder
        ) else {
            reload()
            return nil
        }
        do {
            if moved != source {
                try rebaseIndexedBodies(from: source, to: moved)
                do {
                    let movedParent = (moved as NSString).deletingLastPathComponent
                    try FileManager.default.createDirectory(
                        atPath: movedParent,
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(atPath: source, toPath: moved)
                } catch {
                    try? rebaseIndexedBodies(from: moved, to: source)
                    throw error
                }
                postRelocation(from: source, to: moved)
            }
        } catch {
            reload()
            return nil
        }
        reload()
        return moved
    }

    /// Keep `index.json` pointing at bodies a raw tree move/rename relocated.
    /// An indexed note that was filed into the tree (or a folder containing
    /// one) moves with plain FileManager calls; without the rebase its index
    /// record silently orphans and `cmux note read/open` loses the note.
    func rebaseIndexedBodies(from oldPath: String, to newPath: String) throws {
        guard let projectRoot else { return }
        try CmuxNoteStore.rebaseBodyPaths(
            projectRoot: projectRoot, fromAbsolutePath: oldPath, toAbsolutePath: newPath
        )
    }

    /// Announce a completed on-disk relocation so open viewers (markdown
    /// panels on the moved note, or on notes inside a moved/renamed folder)
    /// re-point at the new path instead of going "File unavailable".
    func postRelocation(from oldPath: String, to newPath: String) {
        let old = (oldPath as NSString).standardizingPath
        let new = (newPath as NSString).standardizingPath
        guard old != new else { return }
        NotificationCenter.default.post(
            name: .cmuxNoteFileRelocated,
            object: nil,
            userInfo: ["oldPath": old, "newPath": new]
        )
    }

    /// Move a note/folder to the system trash. Confined to the project's
    /// `.cmux/notes` directory so the tree can never delete outside the notes
    /// store.
    func delete(path: String) {
        guard isMutablePath(path) else { return }
        var removedRecords: [CmuxNoteRecord] = []
        if let projectRoot {
            do {
                removedRecords = try CmuxNoteStore.removeRecords(
                    underAbsolutePath: path,
                    projectRoot: projectRoot
                )
            } catch {
                reload()
                return
            }
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            if let projectRoot {
                try? CmuxNoteStore.restoreRecords(removedRecords, projectRoot: projectRoot)
            }
            // Trash can fail (permissions, volumes without Trash, transient
            // FS errors); the file is still on disk, so the index must keep
            // its records — dropping them would orphan an existing note.
            reload()
            return
        }
        reload()
    }
}
