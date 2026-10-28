import Foundation

/// The folders whose files a page may save besides the documents the user granted (coordinator
/// rule: only folders the USER chose, the `files.roots` setting). Nothing is inferred: no
/// terminal working directory, no repository top level, never home itself or `/`, which would
/// make every file writable.
nonisolated struct FileWorkspaceRoots: Sendable, Equatable {
    /// Real paths, in the order given, without duplicates.
    let paths: [String]

    init(folders: [String], home: String = NSHomeDirectory()) {
        let excluded: Set<String> = ["/", Self.real(home)]
        var seen: Set<String> = []
        paths = folders.filter { !$0.isEmpty }.map(Self.real).filter { !excluded.contains($0) && seen.insert($0).inserted }
    }

    /// Whether some root contains `path` (links resolved first).
    func contains(_ path: String) -> Bool {
        let real = Self.real(path)
        return paths.contains { real == $0 || real.hasPrefix($0 + "/") }
    }

    static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// What one file page tab may open and save besides the roots, file by file (canonical paths).
    /// A discarded tab's next provider starts with its last provider's (`memoryDiscardInternalPages`),
    /// so a discard changes no file's grant: a file the page followed in place stays
    /// shown, not granted, and the page can still go back to what it showed.
    struct Grants: Sendable, Equatable {
        /// The tab's documents, whoever opened them: its first document, chooseFile results,
        /// approved links. The page may open them, and their folders bound the links that open
        /// without asking.
        var documents: Set<String> = []
        /// The documents the user chose (Open File..., the picker, a click, an approved link): these
        /// are writable. In the code editor, a document an agent or script opened is writable only
        /// inside a user root; every markdown document is writable.
        var granted: Set<String> = []
        /// Documents the host opened read only on purpose (a chat transcript): never saved.
        var readOnlyDocuments: Set<String> = []
        /// Documents the tab has shown (it may reopen them, its own back and forward).
        var shown: Set<String> = []
        /// Markdown files `resolveLinks` found inside a granted document's folder: the page may open
        /// them in place (following a link it showed).
        var linked: Set<String> = []

        init() {}

        /// A tab made on `file`: `userChose` grants it, `readOnly` never saves it.
        init(file: String, userChose: Bool, readOnly: Bool) {
            documents = [file]
            shown = [file]
            if userChose { granted = [file] }
            if readOnly { readOnlyDocuments = [file] }
        }
    }
}
