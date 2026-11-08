public import CmuxNextDaemon
public import CmuxNextSettings
public import Foundation
import os

/// The home daemon's routed `bookmarks.*` ops (cmux-tui spec/page-router.md, owner
/// `bookmarks.tree`). The tree lives there only: every read (a row, a folder's children, the
/// omnibar star's status, the edit bubble's folders, a CLI name) and every edit is one op, and the
/// rules run there (cmux-bookmarks-core and cmux-bookmarks-ops). The app only sends and decodes.
public nonisolated struct BookmarkRoutedClient: Sendable {
    /// The app's JSON (literals, `intValue`, `foundationObject`); the relay's wire value is
    /// converted at ``send(_:_:mutation:)`` only.
    public typealias JSONValue = CmuxNextSettings.JSONValue

    /// The home daemon's connection; nil while it is down.
    public let connection: DaemonConnection?

    public init(connection: DaemonConnection?) {
        self.connection = connection
    }

    /// What one browser source's import did.
    public nonisolated struct SourceCounts: Sendable, Equatable {
        public var added = 0
        public var duplicates = 0
        /// The source's folder before the import, as one import node that puts it back (its undo).
        public var previous: JSONValue?
    }

    /// A Netscape file with no bookmark in it.
    public nonisolated struct FileEmpty: Error {}

    /// Runs one routed op. Mutations carry a fresh idempotency key. A refusal of the tree's rules
    /// comes back as ``BookmarkError``.
    func send(_ operation: String, _ params: [String: JSONValue], mutation: Bool = false) async throws -> JSONValue {
        guard let connection else { throw DaemonError.notConnected }
        do {
            let reply = try await ResourceRelayClient(connection: connection).send(
                operation: operation, params: params.mapValues(Self.wire), idempotencyKey: mutation ? UUID().uuidString.lowercased() : nil)
            return Self.value(reply)
        } catch let error as DaemonError {
            throw Self.refusal(error) ?? error
        }
    }

    // MARK: Reads

    /// `profile`'s nodes in listing order (the bar's tree, then Other Bookmarks'); `places` adds
    /// each row's path and display URL.
    public func list(profile: String, places: Bool = false) async throws -> [BookmarkNode] {
        try Self.nodes(try await send("bookmarks.list", ["browser_profile_id": .string(profile), "places": .bool(places)])["bookmarks"])
    }

    /// The nodes under `parent`, `depth` levels down, at most `limit`.
    public func children(of parent: String, profile: String, depth: Int = 1, limit: Int? = nil,
                         places: Bool = false) async throws -> [BookmarkNode] {
        var params: [String: JSONValue] = ["browser_profile_id": .string(profile), "parent": .string(parent),
                                           "depth": .number(Double(depth)), "places": .bool(places)]
        if let limit { params["limit"] = .number(Double(limit)) }
        return try Self.nodes(try await send("bookmarks.children", params)["bookmarks"])
    }

    /// The placed rows of `ids` that exist (at most 1000).
    public func get(_ ids: [String], profile: String) async throws -> [BookmarkNode] {
        guard !ids.isEmpty else { return [] }
        return try Self.nodes(try await send("bookmarks.get", ["browser_profile_id": .string(profile),
                                                               "ids": .array(ids.prefix(1000).map(JSONValue.string))])["bookmarks"])
    }

    /// What the omnibar star and the bookmarks bar of a profile show.
    public nonisolated struct Status: Sendable, Equatable {
        public var revision: Int
        /// The bar has something to show (an item, or Other Bookmarks).
        public var barFilled: Bool
        /// Per URL asked, the ids of the links to the same page (the star edits the first).
        public var matches: [String: [String]]

        public init(revision: Int, barFilled: Bool, matches: [String: [String]]) {
            self.revision = revision
            self.barFilled = barFilled
            self.matches = matches
        }
    }

    /// The status of `profile` for the pages `urls` (at most 1000).
    public func status(profile: String, urls: [String]) async throws -> Status {
        let asked = Array(urls.prefix(1000))
        let result = try await send("bookmarks.status", ["browser_profile_id": .string(profile),
                                                         "urls": .array(asked.map(JSONValue.string))])
        let rows = result["matches"]?.arrayValue ?? []
        var matches: [String: [String]] = [:]
        for (url, row) in zip(asked, rows) { matches[url] = row.arrayValue?.compactMap(\.stringValue) ?? [] }
        return Status(revision: result["bookmarks_revision"]?.intValue ?? 0, barFilled: result["bar_filled"]?.boolValue ?? false,
                      matches: matches)
    }

    /// The roots and every folder in tree order, as `[{id, title, depth}]` (the edit bubble's menu).
    public func folders(profile: String) async throws -> JSONValue {
        try await send("bookmarks.folders", ["browser_profile_id": .string(profile), "bar_title": .string(BookmarkStrings.barTitle),
                                             "other_title": .string(BookmarkStrings.otherBookmarks)])["folders"] ?? .array([])
    }

    /// What a CLI or MCP call names, resolved on the daemon's tree in one read.
    public nonisolated struct Resolved: Sendable {
        public var bookmark: BookmarkNode?
        public var folder: String?
        public var url: URL?
    }

    /// Asks for each part given: the node `bookmark` names (an id, a URL, a title; folders by
    /// title first with `foldersFirst`), the folder `folder` names (`.some(nil)`: the default
    /// folder, `fallback` while it is one), the URL `url` was typed as. A name that resolves to
    /// nothing throws ``BookmarkError`` (`notFound`, `invalidParent`, `invalidURL`).
    public func resolve(profile: String, bookmark: String? = nil, foldersFirst: Bool = false, folder: String?? = nil,
                        fallback: String? = nil, url: String? = nil) async throws -> Resolved {
        var params: [String: JSONValue] = ["browser_profile_id": .string(profile), "bar_title": .string(BookmarkStrings.barTitle),
                                           "other_title": .string(BookmarkStrings.otherBookmarks)]
        if let bookmark { params["bookmark"] = .string(bookmark) }
        if foldersFirst { params["folders_first"] = .bool(true) }
        if let folder { params["folder"] = folder.map(JSONValue.string) ?? .null }
        if let fallback { params["fallback_folder"] = .string(fallback) }
        if let url { params["url"] = .string(url) }
        let result = try await send("bookmarks.resolve", params)
        return Resolved(bookmark: try result["bookmark"].map { try Self.node($0) }, folder: result["folder"]?.stringValue,
                        url: result["url"]?.stringValue.flatMap(URL.init(string:)))
    }

    /// Nodes whose title or URL holds every term of `text`, in tree order (folders by title).
    public func search(_ text: String, profile: String, limit: Int? = nil, places: Bool = false) async throws -> [BookmarkNode] {
        var params: [String: JSONValue] = ["browser_profile_id": .string(profile), "text": .string(text), "places": .bool(places)]
        if let limit { params["limit"] = .number(Double(limit)) }
        return try Self.nodes(try await send("bookmarks.search", params)["bookmarks"])
    }

    /// URL bookmarks for `text` in the omnibar's order, best first, one per page.
    public func rank(_ text: String, profile: String, limit: Int) async throws -> [BookmarkNode] {
        let result = try await send("bookmarks.rank", ["browser_profile_id": .string(profile), "text": .string(text),
                                                       "limit": .number(Double(limit))])
        return try Self.nodes(.array(result["matches"]?.arrayValue?.compactMap { $0["bookmark"] } ?? []))
    }

    /// `profile`'s tree as a Netscape bookmark file.
    public func exportHTML(profile: String) async throws -> String {
        let result = try await send("bookmarks.export", ["browser_profile_id": .string(profile),
                                                         "bar_title": .string(BookmarkStrings.barTitle)])
        guard let html = result["html"]?.stringValue else { throw DaemonError.connectionClosed(reason: "bookmarks.export answered without html") }
        return html
    }

    // MARK: Edits

    /// The daemon's ops in turn (`bookmarks.apply`, at most 256): a refusal stops there and throws.
    @discardableResult
    public func apply(_ ops: [Op]) async throws -> JSONValue {
        try await send("bookmarks.apply", ["ops": .array(ops.map(\.json))], mutation: true)
    }

    /// One op of `bookmarks.apply`, in the daemon's op JSON (cmux-bookmarks-core `BookmarkOp`).
    public nonisolated struct Op: Sendable, Equatable {
        public let json: JSONValue

        /// A link or folder; `id` nil lets the daemon mint one, `index` nil appends.
        public static func create(id: String?, profile: String, parent: String, index: Int? = nil, folder: Bool,
                                  title: String, url: URL? = nil, created: Date? = nil) -> Op {
            Op(json: .object([
                "op": "create", "id": id.map(JSONValue.string) ?? .null, "browser_profile_id": .string(profile),
                "parent": .string(parent), "index": index.map { .number(Double($0)) } ?? .null,
                "kind": .string(folder ? "folder" : "url"), "title": .string(title),
                "url": url.map { .string($0.absoluteString) } ?? .null, "favicon_key": .null, "source_key": .null,
                "created_ms": created.map { .number(Double(BookmarkTime.ms($0))) } ?? .null,
            ]))
        }

        /// Changes the fields given; `icon` and `lastUsed` take `.null` to clear.
        public static func update(id: String, title: String? = nil, url: URL? = nil, icon: JSONValue? = nil,
                                  lastUsed: Date? = nil) -> Op {
            var object: [String: JSONValue] = ["op": "update", "bookmark": .string(id)]
            if let title { object["title"] = .string(title) }
            if let url { object["url"] = .string(url.absoluteString) }
            if let icon { object["icon"] = icon }
            if let lastUsed { object["last_used_ms"] = .number(Double(BookmarkTime.ms(lastUsed))) }
            return Op(json: .object(object))
        }

        /// `index` is the final position among the destination's children (clamped: a large one appends).
        public static func move(id: String, parent: String, index: Int) -> Op {
            Op(json: ["op": "move", "bookmark": .string(id), "parent": .string(parent), "index": .number(Double(index))])
        }

        public static func delete(id: String) -> Op {
            Op(json: ["op": "delete", "bookmark": .string(id)])
        }

        /// Import nodes (`{kind, title, url?, created_ms?, children?}`) under `parent`; with
        /// `sourceKey` and `replace`, they replace that source's folder in place.
        public static func importNodes(_ nodes: [JSONValue], profile: String, parent: String, index: Int? = nil,
                                       sourceKey: String? = nil, replace: Bool = false) -> Op {
            Op(json: .object([
                "op": "import", "browser_profile_id": .string(profile), "parent": .string(parent),
                "index": index.map { .number(Double($0)) } ?? .null, "source_key": sourceKey.map(JSONValue.string) ?? .null,
                "replace": .bool(replace), "nodes": .array(nodes),
            ]))
        }

        /// A folder of links as one import node.
        public static func folderNode(_ title: String, links: [(title: String, url: URL)]) -> JSONValue {
            .object(["kind": "folder", "title": .string(title), "children": .array(links.map { link in
                .object(["kind": "url", "title": .string(link.title), "url": .string(link.url.absoluteString)])
            })])
        }
    }

    /// A Netscape file into one new `folderTitle` folder at the end of the bar. Throws
    /// ``FileEmpty`` when the file holds no bookmark.
    public func importHTML(_ html: String, folderTitle: String, profile: String) async throws {
        do {
            _ = try await send("bookmarks.import_html", [
                "browser_profile_id": .string(profile), "html": .string(html),
                "folder_title": .string(folderTitle), "bar_title": .string(BookmarkStrings.barTitle),
            ], mutation: true)
        } catch let error as DaemonError where Self.ownerCode(error) == "bookmarks.empty" {
            throw FileEmpty()
        }
    }

    /// One browser source's bookmarks replace its folder on the bar (one folder per source,
    /// replaced in place); no items removes it. The counts say what the folder was before.
    @discardableResult
    public func importSource(_ items: [BookmarkImportItem], title: String, sourceKey: String, profile: String) async throws
        -> SourceCounts {
        let rows: [JSONValue] = items.map { item in
            var row: [String: JSONValue] = ["title": .string(item.title), "url": .string(item.url.absoluteString),
                                            "folder_path": .array(item.folderPath.map(JSONValue.string))]
            if let created = item.created { row["created_ms"] = .number(Double(BookmarkTime.ms(created))) }
            return .object(row)
        }
        let result = try await send("bookmarks.import_source", [
            "browser_profile_id": .string(profile), "title": .string(title), "source_key": .string(sourceKey),
            "items": .array(rows),
        ], mutation: true)
        let previous = result["previous"].flatMap { $0.isNull ? nil : $0 }
        return SourceCounts(added: Int(result["added"]?.doubleValue ?? 0), duplicates: Int(result["duplicates"]?.doubleValue ?? 0),
                            previous: previous)
    }

    /// Removes one browser source's folder in the daemon (one transaction). A failure is logged.
    public func removeSource(_ sourceKey: String, profile: String) {
        // task-owner: one routed removal per undone source; ends with its reply
        Task {
            do { try await importSource([], title: "", sourceKey: sourceKey, profile: profile) } catch {
                Self.logger.error("undo bookmarks import \(sourceKey, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// An older build's `bookmarks.json` (its text) into the daemon, node by node with its ids;
    /// a copy that stopped resumes. Returns how many ops it ran.
    @discardableResult
    public func importLegacyFile(_ document: String) async throws -> Int {
        try await send("bookmarks.import_legacy_file", ["document": .string(document)], mutation: true)["ops"]?.intValue ?? 0
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "bookmarks")

    static func nodes(_ value: JSONValue?) throws -> [BookmarkNode] {
        guard let value else { return [] }
        return try JSONDecoder().decode([BookmarkNode].self, from: JSONEncoder().encode(value))
    }

    static func node(_ value: JSONValue) throws -> BookmarkNode {
        try JSONDecoder().decode(BookmarkNode.self, from: JSONEncoder().encode(value))
    }

    /// The routed owner's own code (`details.extra.code`), if the daemon refused with one.
    /// The app's JSON as the relay's wire value, and back.
    static func wire(_ value: JSONValue) -> CmuxNextDaemon.JSONValue {
        switch value {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): .number(number)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(wire))
        case .object(let members): .object(members.mapValues(wire))
        }
    }

    static func value(_ wire: CmuxNextDaemon.JSONValue) -> JSONValue {
        switch wire {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): .number(number)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(value))
        case .object(let members): .object(members.mapValues(value))
        }
    }

    static func ownerCode(_ error: DaemonError) -> String? {
        guard case .command(_, _, _, let details, _) = error else { return nil }
        return details?["extra"]?["code"]?.stringValue
    }

    /// The tree's rule that refused, from the owner's `reason` (an op's refusal) or its code (a
    /// name that resolved to nothing); nil for any other failure.
    static func refusal(_ error: DaemonError) -> BookmarkError? {
        guard case .command(_, _, _, let details, _) = error, let extra = details?["extra"] else { return nil }
        switch extra["reason"]?.stringValue ?? extra["code"]?.stringValue {
        case "not_found", "bookmarks.not_found": return .notFound("")
        case "invalid_parent", "bookmarks.not_folder": return .invalidParent("")
        case "cycle": return .cycle
        case "invalid_url", "bookmarks.invalid_url": return .invalidURL
        case "invalid_kind": return .invalidKind
        case "too_large": return .tooLarge
        case "too_deep": return .tooDeep
        default: return nil
        }
    }
}
