public import CmuxNextDaemon
import Foundation

/// The home daemon's routed `bookmarks.*` ops (cmux-tui spec/page-router.md, owner
/// `bookmarks.tree`): the Netscape file, the imports, the search and the omnibar rank run there
/// (cmux-bookmarks-ops), on the tree the daemon stores. The app only sends and decodes.
public struct BookmarkRoutedClient: Sendable {
    /// The home daemon's connection; nil while it is down.
    public let connection: DaemonConnection?

    public init(connection: DaemonConnection?) {
        self.connection = connection
    }

    /// What one browser source's import did.
    public struct SourceCounts: Sendable, Equatable {
        public var added = 0
        public var duplicates = 0
    }

    /// A Netscape file with no bookmark in it.
    public struct FileEmpty: Error {}

    /// Runs one routed op. Mutations carry a fresh idempotency key.
    func send(_ operation: String, _ params: [String: JSONValue], mutation: Bool = false) async throws -> JSONValue {
        guard let connection else { throw DaemonError.notConnected }
        return try await ResourceRelayClient(connection: connection).send(
            operation: operation, params: params, idempotencyKey: mutation ? UUID().uuidString.lowercased() : nil)
    }

    /// `profile`'s tree as a Netscape bookmark file.
    public func exportHTML(profile: String) async throws -> String {
        let result = try await send("bookmarks.export", ["browser_profile_id": .string(profile),
                                                         "bar_title": .string(BookmarkStrings.barTitle)])
        guard let html = result["html"]?.stringValue else { throw DaemonError.connectionClosed(reason: "bookmarks.export answered without html") }
        return html
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
    /// replaced in place); no items removes it.
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
        return SourceCounts(added: Int(result["added"]?.doubleValue ?? 0), duplicates: Int(result["duplicates"]?.doubleValue ?? 0))
    }

    /// Nodes whose title or URL holds every term of `text`, in tree order (folders by title).
    public func search(_ text: String, profile: String, limit: Int? = nil) async throws -> [BookmarkNode] {
        var params: [String: JSONValue] = ["browser_profile_id": .string(profile), "text": .string(text)]
        if let limit { params["limit"] = .number(Double(limit)) }
        return try Self.nodes(try await send("bookmarks.search", params)["bookmarks"])
    }

    /// URL bookmarks for `text` in the omnibar's order, best first, one per page.
    public func rank(_ text: String, profile: String, limit: Int) async throws -> [BookmarkNode] {
        let result = try await send("bookmarks.rank", ["browser_profile_id": .string(profile), "text": .string(text),
                                                       "limit": .number(Double(limit))])
        return try Self.nodes(.array(result["matches"]?.arrayValue?.compactMap { $0["bookmark"] } ?? []))
    }

    static func nodes(_ value: JSONValue?) throws -> [BookmarkNode] {
        guard let value else { return [] }
        return try JSONDecoder().decode([BookmarkNode].self, from: JSONEncoder().encode(value))
    }

    /// The routed owner's own code (`details.extra.code`), if the daemon refused with one.
    static func ownerCode(_ error: DaemonError) -> String? {
        guard case .command(_, _, _, let details, _) = error else { return nil }
        return details?["extra"]?["code"]?.stringValue
    }
}
