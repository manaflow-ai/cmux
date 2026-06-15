import Foundation

extension CmuxNoteStore {
    static func absoluteBodyPath(bodyPath: String, projectRoot: String) -> String {
        // `bodyPath` comes from project-controlled `.cmux/notes/index.json`, so an
        // absolute path, `..` traversal, or a committed symlink must never let note
        // read/write/append/rm escape the notes directory. Canonical body paths are
        // `notes/<id>.md` relative to `.cmux`; containment is checked on the
        // symlink-resolved path (a repo can commit a link under `.cmux/notes`
        // pointing anywhere), and anything resolving outside `.cmux/notes` is
        // confined to that directory by its final path component.
        let notesRoot = ((NoteSupport.notesDirectory(forProjectRoot: projectRoot) as NSString)
            .standardizingPath as NSString).resolvingSymlinksInPath
        let resolved: String
        if bodyPath.hasPrefix("/") {
            resolved = URL(fileURLWithPath: bodyPath).standardizedFileURL.path
        } else {
            let cmuxDir = (projectRoot as NSString).appendingPathComponent(".cmux")
            let joined = (cmuxDir as NSString).appendingPathComponent(bodyPath)
            resolved = URL(fileURLWithPath: joined).standardizedFileURL.path
        }
        let canonical = (resolved as NSString).resolvingSymlinksInPath
        if canonical == notesRoot || canonical.hasPrefix(notesRoot + "/") {
            return canonical
        }
        let leaf = (bodyPath as NSString).lastPathComponent
        let safeLeaf = (leaf.isEmpty || leaf == "." || leaf == "..") ? "untrusted-note.md" : leaf
        // The confined leaf can itself be the committed symlink that caused
        // the escape (`notes/link.md -> /elsewhere`); returning it would hand
        // read/write/append the same link. Walk to the first name whose final
        // component is not a symlink so note IO can never follow one out.
        let fm = FileManager.default
        func isSymlink(_ path: String) -> Bool {
            ((try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink
        }
        var candidate = (notesRoot as NSString).appendingPathComponent(safeLeaf)
        var counter = 2
        while isSymlink(candidate) {
            let stem = (safeLeaf as NSString).deletingPathExtension
            let ext = (safeLeaf as NSString).pathExtension
            let next = ext.isEmpty
                ? "\(stem)-untrusted-\(counter)"
                : "\(stem)-untrusted-\(counter).\(ext)"
            candidate = (notesRoot as NSString).appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    static func noteBodyPath(for note: CmuxNoteRecord, projectRoot: String) -> String {
        absoluteBodyPath(bodyPath: note.bodyPath, projectRoot: projectRoot)
    }
}
