import CmuxNextCompat
public import Foundation

/// What the app hands the daemon from a folder macOS protects: Safari's, and every app's sandbox
/// and group container. The daemon refuses those folders (`cmux_browser_import::ops::PROTECTED`):
/// it may run without Full Disk Access, and an agent must never read one by asking it. So the app
/// reads the files a read opens there and sends their bytes, in chunks, into an upload the daemon
/// holds in memory (`upload.append`), names the upload in the read, then drops it (`upload.drop`).
/// Nothing is ever copied to disk, where any process of the same user could read it. The lists
/// are fixed and nothing here parses a file's contents; the readers are the daemon's.
public struct ProtectedProfileUpload: Sendable {
    /// The folders under the home the daemon refuses (the crate's `ops::PROTECTED`).
    public static let protectedFolders = ["Library/Safari", "Library/SafariTechnologyPreview", "Library/Containers", "Library/Group Containers"]
    /// A profile's files the readers open (Chromium and Firefox): preferences, databases, session
    /// stores and the search engine store.
    public static let profileFiles = [
        "Preferences", "Secure Preferences", "Web Data", "Bookmarks", "History", "Current Session", "places.sqlite",
        "sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/previous.jsonlz4",
        "search.json.mozlz4",
    ]
    /// A profile's folders whose files are sent: Chromium's session command logs.
    public static let profileFolders = ["Sessions"]
    /// What a database brings along, so its newest writes are read too (the daemon replays it).
    public static let databaseSidecars = ["-wal"]
    /// The most bytes one `upload.append` carries: as base64 in its envelope it stays under the
    /// daemon's 4 MiB message limit.
    public static let chunkBytes = 2 << 20

    /// Where a read finds its files: a path on disk, or a name in an upload.
    public struct Source: Sendable, Equatable {
        public var path: String
        public var upload: String?
    }

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

    /// `file` itself when it is not protected; else it and its sidecars sent into an upload,
    /// held while `body` runs.
    public func file<T>(_ file: URL, over transport: BrowserDataReader.Transport, _ body: (Source) async throws -> T) async throws -> T {
        guard isProtected(file) else { return try await body(Source(path: file.path)) }
        let name = file.lastPathComponent
        let names = [name] + Self.databaseSidecars.map { name + $0 }
        return try await upload(from: file.deletingLastPathComponent(), names: names, over: transport) {
            try await body(Source(path: name, upload: $0))
        }
    }

    /// `profile` itself when it is not protected; else the files the readers open there
    /// (``profileFiles``, the files of ``profileFolders``, each extension's manifest and messages)
    /// sent into an upload, held while `body` runs. The upload's top folder is `.`.
    public func profile<T>(_ profile: URL, over transport: BrowserDataReader.Transport, _ body: (Source) async throws -> T) async throws -> T {
        guard isProtected(profile) else { return try await body(Source(path: profile.path)) }
        let files = Self.profileFiles.flatMap { name in ([""] + Self.databaseSidecars).map { name + $0 } }
        let folders = Self.profileFolders.flatMap { folder in Self.names(in: profile, folder).map { "\(folder)/\($0)" } }
        let names = files + folders + Self.extensionFiles(in: profile)
        return try await upload(from: profile, names: names, over: transport) { try await body(Source(path: ".", upload: $0)) }
    }

    /// `Extensions/<id>/<version>/manifest.json` and each `_locales/<locale>/messages.json` of it.
    static func extensionFiles(in profile: URL) -> [String] {
        names(in: profile, "Extensions").flatMap { id in
            names(in: profile, "Extensions/\(id)").flatMap { version in
                let base = "Extensions/\(id)/\(version)"
                return ["\(base)/manifest.json"] + names(in: profile, "\(base)/_locales").map { "\(base)/_locales/\($0)/messages.json" }
            }
        }
    }

    private static func names(in profile: URL, _ path: String) -> [String] {
        (try? FileManager.checked.contentsOfDirectory(atPath: profile.appending(path: path).path)) ?? []
    }

    // MARK: The upload

    private struct Append: Encodable {
        var reader = "upload.append"
        var upload: String
        var name: String
        var base64: Data
    }

    private struct Drop: Encodable {
        var reader = "upload.drop"
        var upload: String
    }

    private struct Reply: Decodable {
        var error: BrowserDataReader.Failure?
    }

    /// Sends each of `names` under `folder` (a missing one is skipped) into a new upload, runs
    /// `body` with its id, and drops it however `body` ends.
    private func upload<T>(from folder: URL, names: [String], over transport: BrowserDataReader.Transport,
                           _ body: (String) async throws -> T) async throws -> T {
        let id = UUID().uuidString
        let dropRequest = try JSONEncoder().encode(Drop(upload: id))
        do {
            for name in names { try await send(folder.appending(path: name), as: name, to: id, over: transport) }
            let result = try await body(id)
            _ = try? await transport(dropRequest)
            return result
        } catch {
            _ = try? await transport(dropRequest)
            throw error
        }
    }

    /// One file, ``chunkBytes`` at a time (an empty file is one empty chunk). A daemon error
    /// (`tooLarge`: over its cap) throws.
    private func send(_ file: URL, as name: String, to id: String, over transport: BrowserDataReader.Transport) async throws {
        let attributes = try? FileManager.checked.attributesOfItem(atPath: file.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        // The size when it was opened bounds the chunks (a file still growing ends there).
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        for _ in stride(from: 0, to: max(size, 1), by: Self.chunkBytes) {
            let chunk = try handle.read(upToCount: Self.chunkBytes) ?? Data()
            let reply = try await transport(try JSONEncoder().encode(Append(upload: id, name: name, base64: chunk)))
            if let error = try JSONDecoder().decode(Reply.self, from: reply).error { throw error }
            if chunk.count < Self.chunkBytes { return }
        }
    }
}

extension ProtectedProfileUpload.Source {
    init(path: String) {
        self.init(path: path, upload: nil)
    }
}
