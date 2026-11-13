import CmuxNextCompat
public import Foundation

/// What the app hands the daemon from a folder macOS protects: Safari's, and every app's sandbox
/// and group container. The daemon refuses those folders (`cmux_browser_import::ops::PROTECTED`):
/// it may run without Full Disk Access, and an agent must never read one by asking it. So the app
/// copies the files a read opens into a private folder of its own and names the copy. The lists
/// are fixed and nothing here opens a file's contents; the readers are the daemon's.
public struct ProtectedProfileCopy: Sendable {
    /// The folders under the home the daemon refuses (the crate's `ops::PROTECTED`).
    public static let protectedFolders = ["Library/Safari", "Library/SafariTechnologyPreview", "Library/Containers", "Library/Group Containers"]
    /// A profile's files the readers open (Chromium and Firefox): preferences, databases, session
    /// stores and the search engine store.
    public static let profileFiles = [
        "Preferences", "Secure Preferences", "Web Data", "Bookmarks", "History", "Current Session", "places.sqlite",
        "sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/previous.jsonlz4",
        "search.json.mozlz4",
    ]
    /// A profile's folders copied whole: Chromium's session command logs.
    public static let profileFolders = ["Sessions"]
    /// What a database brings along, so its newest writes are read too.
    public static let databaseSidecars = ["-wal", "-journal"]

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// `url` is under one of the home's protected folders, as written or with its links resolved
    /// (the Mac's volume ignores case).
    public func isProtected(_ url: URL) -> Bool {
        let roots = Self.protectedFolders.map { home.appending(path: $0).standardizedFileURL.path.lowercased() + "/" }
        return [url.standardizedFileURL, url.resolvingSymlinksInPath()].contains { candidate in
            let path = candidate.path.lowercased() + "/"
            return roots.contains { path.hasPrefix($0) }
        }
    }

    /// `file` itself when it is not protected; else a private copy of it and its sidecars, kept
    /// while `body` runs.
    public func file<T>(_ file: URL, _ body: (URL) async throws -> T) async throws -> T {
        guard isProtected(file) else { return try await body(file) }
        let folder = try StagedFolder()
        defer { folder.remove() }
        let name = file.lastPathComponent
        for suffix in [""] + Self.databaseSidecars { folder.copy(name + suffix, from: file.deletingLastPathComponent()) }
        return try await body(folder.url.appending(path: name))
    }

    /// `profile` itself when it is not protected; else a private copy of the files the readers open
    /// there (``profileFiles``, ``profileFolders``, each extension's manifest and messages), kept
    /// while `body` runs.
    public func profile<T>(_ profile: URL, _ body: (URL) async throws -> T) async throws -> T {
        guard isProtected(profile) else { return try await body(profile) }
        let folder = try StagedFolder()
        defer { folder.remove() }
        let files = Self.profileFiles.flatMap { name in ([""] + Self.databaseSidecars).map { name + $0 } }
        for name in files + Self.profileFolders + Self.extensionFiles(in: profile) { folder.copy(name, from: profile) }
        return try await body(folder.url)
    }

    /// `Extensions/<id>/<version>/manifest.json` and each `_locales/<locale>/messages.json` of it.
    static func extensionFiles(in profile: URL) -> [String] {
        func names(_ path: String) -> [String] {
            (try? FileManager.checked.contentsOfDirectory(atPath: profile.appending(path: path).path)) ?? []
        }
        return names("Extensions").flatMap { id in
            names("Extensions/\(id)").flatMap { version in
                let base = "Extensions/\(id)/\(version)"
                return ["\(base)/manifest.json"] + names("\(base)/_locales").map { "\(base)/_locales/\($0)/messages.json" }
            }
        }
    }
}

/// A private folder (owner only) under the temporary folder; its user removes it.
struct StagedFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "cmux-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.checked.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func remove() {
        try? FileManager.checked.removeItem(at: url)
    }

    /// Copies `name` (a file or folder under `source`) to the same name here; a missing one is skipped.
    func copy(_ name: String, from source: URL) {
        let from = source.appending(path: name), to = url.appending(path: name)
        guard FileManager.checked.fileExists(atPath: from.path) else { return }
        try? FileManager.checked.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.checked.copyItem(at: from, to: to)
    }
}
