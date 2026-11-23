import Foundation
import CmuxNextCompat
import CmuxNextSettings

/// The New Tab omnibar's folder completion (`folder.complete {path}`): the subfolders of one
/// absolute folder, names only, for "Codex in ~/fun/cm…" (webviews newtab/launchRows.ts). The page
/// reads no disk; it asks once per folder after the field stays still and completes from the answer
/// on each key, so a keystroke never waits on the disk.
///
/// Never a listing inside a privacy-protected folder (LAUNCH-NO-TCC-PROMPTS): the folder goes through
/// `ChatRootValidator` first, by spelling and then by identity (`lstat` only), as project icons do
/// (``AgentPaneProjectIcon``), and is listed only when both pass. The home folder itself is listed
/// (its children are where projects live) but its protected children (Documents, Desktop, …) are
/// left out of the answer and never stat'ed. Hidden folders, packages (`.app`) and files are left out.
nonisolated struct AgentPaneFolderCompletion: Sendable {
    /// The most names one answer carries: a folder of thousands lists its first ones by name.
    static let maximumNames = 200
    /// The most entries read from one folder before it stops (a huge folder stays bounded).
    static let maximumEntries = 4000

    /// A folder's subfolders (not packages) among the entries `keep` accepts by name, or nil. `keep`
    /// runs on each name before anything is read about that entry, so a protected one is never stat'ed.
    var list: @Sendable (_ path: String, _ keep: (String) -> Bool) -> [String]?
    private let validator: ChatRootValidator

    init(home: String = NSHomeDirectory()) {
        validator = ChatRootValidator(home: home)
        list = { path, keep in
            // Names only (the hidden flag aside): no entry's attributes are read here.
            guard let entries = try? FileManager.checked.contentsOfDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else { return nil }
            return entries.prefix(AgentPaneFolderCompletion.maximumEntries).compactMap { entry in
                let name = entry.lastPathComponent
                guard keep(name) else { return nil }
                // A stat (no privacy prompt); a folder whose name has an extension may be a package.
                let keys: Set<URLResourceKey> = name.contains(".") ? [.isDirectoryKey, .isPackageKey] : [.isDirectoryKey]
                guard let values = try? entry.blockingResourceValues(forKeys: keys), values.isDirectory == true,
                      values.isPackage != true else { return nil }
                return name
            }
        }
    }

    /// For tests: a fake disk. `list` answers a folder's subfolders; `keep` still filters them.
    init(home: String, list: @escaping @Sendable (String) -> [(name: String, folder: Bool)]?) {
        validator = ChatRootValidator(home: home)
        self.list = { path, keep in list(path)?.filter { $0.folder && keep($0.name) }.map(\.name) }
    }

    /// ``folders(in:)`` off the caller's actor: the page's request waits, the main thread never does.
    @concurrent func foldersInBackground(_ path: String) async -> [String]? { folders(in: path) }

    /// The subfolders of `path`, sorted by name, or nil when it may not be listed or is no folder.
    func folders(in path: String) -> [String]? {
        guard Self.isWellFormed(path), allowed(path, home: true) else { return nil }
        let base = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path == "/" ? "" : path
        // One answer's checks share their folders' lookups (ChatRootValidator.batch).
        let batch = validator.batch()
        // A protected child of the home folder (Documents) is never offered or stat'ed: picking it
        // would open it. Its spelling is enough.
        // The home folder itself ("/Users/me" in "/Users/") is refused as a chat root, yet it is
        // how an absolute path reaches the projects under it: it is offered.
        let home = validator.home
        guard let names = list(base.isEmpty ? "/" : base, { name in
            guard !name.hasPrefix(".") else { return false }
            let child = "\(base)/\(name)"
            return child == home || batch.refusal(child) == nil
        }) else { return nil }
        return Array(names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(Self.maximumNames))
    }

    /// An absolute path the page may ask about: no NUL, no `..` part, at most 4096 bytes.
    static func isWellFormed(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\u{0}")
            && !path.split(separator: "/").contains("..")
    }

    /// True when `path` may be listed: refused neither by its spelling nor by what it reaches. The
    /// home folder and `/` are refused as chat roots, yet listing their children reads nothing
    /// protected; `home` allows them.
    private func allowed(_ path: String, home: Bool) -> Bool {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if home, trimmed == "/" || trimmed == validator.home { return !validator.reachesProtectedFolder(trimmed) }
        return validator.refusal(trimmed) == nil && !validator.reachesProtectedFolder(trimmed)
    }
}
