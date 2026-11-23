public import Foundation

// The Community shelf's replies (`apps.catalog.list|get {source: "community"}`, the extensions-community
// lane's owner): repo extensions and setups people publish, read from the owner's disk cache. Read
// tolerantly, as the store's other replies.

/// One community listing (`listings[]`, `on_other_devices[]`).
public nonisolated struct AppStoreCommunityRow: Sendable, Hashable, Identifiable {
    /// `github.com/OWNER/REPO[/PATH]`.
    public var ref: String
    /// The app id once the owner knows it.
    public var app: String?
    /// `extension` or `setup`.
    public var kind: String
    public var name: String
    public var tagline: String?
    public var description: String
    public var author: String
    public var authorURL: URL?
    public var repository: URL?
    public var pageURL: URL?
    public var categories: [String]
    public var downloads: Int
    public var stars: Int
    public var updatedAt: Date?
    public var version: String?
    public var minCmux: String?
    public var commit: String?
    /// The app id `apps.install` takes for it.
    public var installApp: String?
    public var installed: Bool
    /// The other device it is installed on (an `on_other_devices` row), when the owner names it.
    public var device: String?
    public var id: String { ref }

    /// The row's one line: its tagline, else its description.
    public var oneLine: String { tagline ?? description }

    init?(json: AppJSON) {
        guard let ref = json["ref"]?.stringValue, !ref.isEmpty else { return nil }
        self.ref = ref
        app = json["app"]?.stringValue
        kind = json["kind"]?.stringValue ?? "extension"
        name = json["name"]?.stringValue ?? ref
        tagline = json["tagline"]?.stringValue.flatMap(AppStoreItem.text)
        description = json["description"]?.stringValue ?? ""
        author = json["author"]?.stringValue ?? ""
        authorURL = json["author_url"]?.stringValue.flatMap(URL.init(string:))
        repository = json["repository"]?.stringValue.flatMap(URL.init(string:))
        pageURL = json["page_url"]?.stringValue.flatMap(URL.init(string:))
        categories = json["categories"]?.arrayValue?.compactMap(\.stringValue) ?? []
        downloads = json["downloads"]?.numberValue.map { Int($0) } ?? 0
        stars = json["stars"]?.numberValue.map { Int($0) } ?? 0
        updatedAt = json["updated_at"]?.stringValue.flatMap(AppStoreCommunityWire.date)
        version = (json["version"]?.stringValue ?? json["latest_release"]?.stringValue).flatMap(AppStoreItem.text)
        minCmux = json["min_cmux"]?.stringValue.flatMap(AppStoreItem.text)
        commit = json["commit"]?.stringValue
        installApp = (json["install_app"]?.stringValue ?? json["app"]?.stringValue).flatMap(AppStoreItem.text)
        installed = json["installed"]?.boolValue ?? false
        device = (json["device"]?.stringValue ?? json["device_name"]?.stringValue).flatMap(AppStoreItem.text)
    }
}

/// One `catalog.list {source: "community"}` reply, its pages joined.
public nonisolated struct AppStoreCommunityPage: Sendable, Hashable {
    public var rows: [AppStoreCommunityRow]
    /// Installed on the person's other devices, not on this Mac.
    public var elsewhere: [AppStoreCommunityRow]
    /// The cache is older than the owner wants, or a refresh runs now: the view says "Updating…".
    public var updating: Bool
    /// The owner's last refresh failed (the cache still shows).
    public var error: String?
}

/// `catalog.get {source: "community", ref}`.
public nonisolated struct AppStoreCommunityDetail: Sendable, Hashable, Identifiable {
    public var row: AppStoreCommunityRow
    public var readme: String
    public var changelog: String?
    public var license: String?
    public var versions: [AppStoreVersionRow]
    public var id: String { row.ref }

    init?(json: AppJSON) {
        guard let row = AppStoreCommunityRow(json: json) else { return nil }
        self.row = row
        readme = json["readme"]?.stringValue ?? ""
        changelog = json["changelog"]?.stringValue.flatMap(AppStoreItem.text)
        license = json["license"]?.stringValue.flatMap(AppStoreItem.text)
        versions = (json["versions"]?.arrayValue ?? []).compactMap { version in
            guard let name = version["version"]?.stringValue, !name.isEmpty else { return nil }
            return AppStoreVersionRow(version: name, tag: version["tag"]?.stringValue, commit: version["commit"]?.stringValue,
                                      date: version["date"]?.stringValue.flatMap(AppStoreCommunityWire.date),
                                      engines: nil, yanked: false)
        }
    }
}

nonisolated enum AppStoreCommunityWire {
    static let source = "community"
    static let kinds = ["extension", "setup"]
    static let sorts = ["featured", "downloads", "updated", "stars", "name"]

    /// The args of one community list read.
    static func listArgs(query: String, kind: String?, sort: String, refresh: Bool, cursor: String?) -> AppJSON {
        var args: [String: AppJSON] = ["source": .string(source), "sort": .string(sort), "limit": .number(Double(AppStoreWire.pageSize))]
        if !query.isEmpty { args["query"] = .string(query) }
        if let kind { args["kind"] = .string(kind) }
        if refresh { args["refresh"] = .bool(true) }
        if let cursor { args["cursor"] = .string(cursor) }
        return .object(args)
    }

    /// One page: its rows, the other devices' rows, the cache state and the next cursor.
    static func page(_ json: AppJSON) -> (page: AppStoreCommunityPage, next: String?) {
        let page = AppStoreCommunityPage(
            rows: (json["listings"]?.arrayValue ?? []).compactMap(AppStoreCommunityRow.init(json:)),
            elsewhere: (json["on_other_devices"]?.arrayValue ?? []).compactMap(AppStoreCommunityRow.init(json:)),
            updating: json["stale"]?.boolValue == true || json["refreshing"]?.boolValue == true,
            error: json["error"]?.stringValue.flatMap(AppStoreItem.text) ?? json["error"]?["message"]?.stringValue)
        return (page, json["next_cursor"]?.stringValue)
    }

    /// An ISO 8601 date, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
