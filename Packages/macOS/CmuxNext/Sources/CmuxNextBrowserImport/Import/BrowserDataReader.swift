public import Foundation

/// Reads another browser's data through the daemon's `browser_import.read` (the
/// `cmux-browser-import` crate holds every reader). The app's transport is
/// `BrowserImportClient.read` on the local daemon; the files a read opens in a
/// folder macOS protects are sent into an upload the daemon holds in memory
/// (``ProtectedProfileUpload``). Each read runs off the caller's actor.
public struct BrowserDataReader: Sendable {
    /// Sends one request's fields as JSON and answers the reply as JSON.
    public typealias Transport = @Sendable (Data) async throws -> Data

    /// A source file that did not read (`kind`: read, open, query, copy, syntax, notBookmarks,
    /// tooLarge: the files sent from a protected folder are over the daemon's cap...).
    public struct Failure: Error, Sendable, Equatable, Decodable, CustomStringConvertible {
        public var kind: String
        public var message: String
        public var description: String { "\(kind): \(message)" }
    }

    /// What `browser.searchEngine` becomes for an imported engine.
    public struct SearchSetting: Sendable, Equatable, Decodable {
        public var engine: String
        public var search: String?
        public var suggest: String?
    }

    /// History a browser exports as JSON (Safari's History.json, Google Takeout's).
    public struct ExportedHistory: Sendable, Decodable {
        public enum Format: String, Sendable, Decodable {
            case safari
            case chromeTakeout
        }

        public var format: Format
        public var entries: [ImportedHistoryEntry]

        enum CodingKeys: String, CodingKey { case format, entries }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(Format.self, forKey: .format)
            entries = try container.decode([Lossy<ImportedHistoryEntry>].self, forKey: .entries).compactMap(\.value)
        }
    }

    let transport: Transport
    private let protected: ProtectedProfileUpload

    public init(protected: ProtectedProfileUpload = ProtectedProfileUpload(), transport: @escaping Transport) {
        self.protected = protected
        self.transport = transport
    }

    /// One history database, newest pages first, with its family's reader.
    @concurrent public func history(_ family: BrowserFamily, file: URL, limit: Int) async throws -> [ImportedHistoryEntry] {
        let reader: String
        switch family {
        case .chromium: reader = "chromium.history"
        case .firefox: reader = "firefox.history"
        case .safari: reader = "safari.history"
        case .webkit, .other: return []
        }
        return try await protected.file(file, over: transport) { try await list(Request(reader: reader, $0, limit: limit)) }
    }

    /// One profile's bookmarks, with the reader its registry row names (engine family, not
    /// browser). A source that does not read throws; private stores give nothing (their HTML
    /// export is the path).
    @concurrent public func bookmarks(_ profile: BrowserSourceProfile) async throws -> [ImportedBookmark] {
        let files = profile.browser.source?.files
        func file(_ fallback: String) -> URL { profile.bookmarksFile ?? profile.path.appending(path: files?.bookmarks ?? fallback) }
        switch profile.browser.bookmarksFormat {
        case .chromiumJSON: return try await read("chromium.bookmarks", file("Bookmarks"))
        case .firefoxPlaces: return try await read("firefox.bookmarks", file("places.sqlite"))
        case .safariPlist: return try await read("safari.bookmarks", file("Bookmarks.plist"))
        case .arcSidebar:
            // No sidebar file: Arc's Chromium `Bookmarks` file is the fallback.
            guard let sidebar = profile.bookmarksFile else {
                return try await read("chromium.bookmarks", profile.path.appending(path: files?.bookmarks ?? "Bookmarks"))
            }
            return try await read("arc.bookmarks", sidebar, profileDirectory: profile.directoryName)
        case .htmlExport, .noStore:
            return []
        }
    }

    /// The tabs of a Chromium or Firefox profile's last session.
    @concurrent public func openTabs(_ profile: BrowserSourceProfile) async throws -> [ImportedTab] {
        let readers: (file: String, tabs: String)
        switch profile.browser.family {
        case .chromium: readers = ("chromium.session_file", "chromium.session")
        case .firefox: readers = ("firefox.session_file", "firefox.session")
        case .safari, .webkit, .other: return []
        }
        return try await protected.profile(profile.path, over: transport) { folder in
            guard let file = try await call(Request(reader: readers.file, profile: folder), as: String.self) else { return [] }
            return try await list(Request(reader: readers.tabs, .init(path: file, upload: folder.upload)))
        }
    }

    /// A profile's default search engine; nil when it keeps the browser's own.
    @concurrent public func searchEngine(_ profile: BrowserSourceProfile) async throws -> ImportedSearchEngine? {
        switch profile.browser.family {
        case .chromium, .firefox:
            let reader = profile.browser.family == .chromium ? "chromium.search_engine" : "firefox.search_engine"
            return try await protected.profile(profile.path, over: transport) { try await call(Request(reader: reader, profile: $0), as: ImportedSearchEngine.self) }
        case .safari:
            return try await call(Request(reader: "safari.search_engine", services: Self.safariServices()), as: ImportedSearchEngine.self)
        case .webkit, .other:
            return nil
        }
    }

    /// A Chromium profile's Web Store extensions.
    @concurrent public func extensions(_ profile: BrowserSourceProfile) async throws -> [ImportedExtension] {
        guard profile.browser.family == .chromium else { return [] }
        return try await protected.profile(profile.path, over: transport) { try await list(Request(reader: "chromium.extensions", profile: $0)) }
    }

    /// The `browser.searchEngine` setting for `engine`: the built-in engine (`builtIn`: id to
    /// search template) with its host, else `custom` with its addresses.
    @concurrent public func setting(_ engine: ImportedSearchEngine, builtIn: [String: String]) async throws -> SearchSetting? {
        try await call(Request(reader: "search_engine.setting", engine: engine, builtIn: builtIn), as: SearchSetting.self)
    }

    /// Whether `head` (a file's first bytes, as text) looks like exported history.
    @concurrent public func looksLikeHistory(_ head: String) async -> Bool {
        (try? await call(Request(reader: "exported_history.looks_like", head: head), as: Bool.self)) ?? false
    }

    /// What an exported file is, by content.
    public enum ExportKind: Sendable {
        case passwords
        case bookmarks
        /// A zip: Safari's Export Browsing Data, or Google Takeout.
        case archive
        /// Safari's History.json or Takeout's Chrome history.
        case history
    }

    /// By content, not name: a zip archive; JSON with a history list; a
    /// Netscape bookmarks file is HTML with a `<DL>` list; any other text
    /// with commas goes to the CSV import, which names a file without
    /// website and password columns.
    @concurrent public func exportKind(of url: URL) async -> ExportKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 4096)) ?? Data()
        if ExportArchive.isArchive(bytes) { return .archive }
        let head = String(decoding: bytes, as: UTF8.self)
        let text = head.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if await looksLikeHistory(String(text)) { return .history }
        if text.first == "<" {
            let upper = text.uppercased()
            return upper.contains("NETSCAPE-BOOKMARK-FILE") || upper.contains("<DL") ? .bookmarks : nil
        }
        return text.contains(",") ? .passwords : nil
    }

    /// Exported history in `json`; nil when it is neither format.
    @concurrent public func exportedHistory(_ json: Data) async throws -> ExportedHistory? {
        try await call(Request(reader: "exported_history.parse", base64: json), as: ExportedHistory.self)
    }

    /// The Mac's web search provider (`NSPreferredWebServices`, set by Safari's Search settings);
    /// nil when Safari keeps its own default.
    public static func safariServices() -> SafariServices? {
        let services = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSPreferredWebServices"] as? [String: Any]
        guard let search = services?["NSWebServicesProviderWebSearch"] as? [String: Any] else { return nil }
        return SafariServices(search: .init(name: search["NSDefaultDisplayName"] as? String, provider: search["NSProviderIdentifier"] as? String))
    }

    /// `NSPreferredWebServices` with the keys `safari.search_engine` reads.
    public struct SafariServices: Sendable, Encodable {
        public struct Provider: Sendable, Encodable {
            var name: String?
            var provider: String?
            enum CodingKeys: String, CodingKey { case name = "NSDefaultDisplayName", provider = "NSProviderIdentifier" }
        }

        var search: Provider
        enum CodingKeys: String, CodingKey { case search = "NSWebServicesProviderWebSearch" }
    }

    // MARK: The wire

    /// `browser_import.read`'s fields; nil ones are left out.
    struct Request: Encodable, Sendable {
        var reader: String
        var path: String?
        var base64: Data?
        var profile: String?
        var profileDirectory: String?
        var limit: Int?
        var head: String?
        var services: SafariServices?
        var engine: ImportedSearchEngine?
        var builtIn: [String: String]?
        /// The upload `path` and `profile` name a file or folder in (``ProtectedProfileUpload``).
        var upload: String?
    }

    private struct Reply<Value: Decodable>: Decodable {
        var ok: Value?
        var error: Failure?
    }

    /// One list element: one that does not decode (an address `URL` refuses) is skipped.
    struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    private func read<Item: Decodable>(_ reader: String, _ file: URL, profileDirectory: String? = nil) async throws -> [Item] {
        try await protected.file(file, over: transport) {
            try await list(Request(reader: reader, path: $0.path, profileDirectory: profileDirectory, upload: $0.upload))
        }
    }

    private func list<Item: Decodable>(_ request: Request) async throws -> [Item] {
        (try await call(request, as: [Lossy<Item>].self) ?? []).compactMap(\.value)
    }

    private func call<Value: Decodable>(_ request: Request, as type: Value.Type) async throws -> Value? {
        let reply = try JSONDecoder().decode(Reply<Value>.self, from: try await transport(try JSONEncoder().encode(request)))
        if let error = reply.error { throw error }
        return reply.ok
    }
}

extension BrowserDataReader.Request {
    /// A read of the file `file` names (a path, or a name in an upload).
    init(reader: String, _ file: ProtectedProfileUpload.Source, limit: Int? = nil) {
        self.init(reader: reader, path: file.path, limit: limit, upload: file.upload)
    }

    /// A read of the folder `profile` names (a path, or `.` in an upload).
    init(reader: String, profile: ProtectedProfileUpload.Source) {
        self.init(reader: reader, profile: profile.path, upload: profile.upload)
    }
}
