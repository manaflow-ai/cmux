public import Foundation

// The native App Store's view of the owner's `cmux.apps/1` replies (cmux-tui-core apps/store.rs), read
// tolerantly: a field an older owner does not send is absent, never an error. Only these types know the
// wire names; the views read the values (webviews/src/pages/apps/wire.ts is the React page's copy).

/// How a listing draws its icon: a package image (`asset.get`) or one of cmux's own glyphs.
public nonisolated enum AppStoreIconRef: Sendable, Hashable {
    /// A path in the package, served by `apps.asset.get`.
    case asset(String)
    /// A symbol name the host draws with its own icon pack.
    case symbol(String)

    init?(_ json: AppJSON?) {
        if let path = json?["asset"]?.stringValue, !path.isEmpty { self = .asset(path) }
        else if let name = json?["symbol"]?.stringValue, !name.isEmpty { self = .symbol(name) }
        else { return nil }
    }
}

/// One store row (`catalog.list` `listings[]`, the head of `catalog.get`).
public nonisolated struct AppStoreItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    /// One line on what the person gets; nil from an older owner or an app with none.
    public var tagline: String?
    public var publisher: String
    public var tier: AppStoreTier
    public var version: String
    public var icon: AppStoreIconRef?
    public var categories: [String]
    /// First-party apps offer Hide and Show only (the owner's word).
    public var hideOnly: Bool
    /// `store`, `example` or `local`; an older owner sends none (`store`).
    public var shelf: String
    public var installed: Bool
    public var enabled: Bool
    public var hidden: Bool
    /// The version an update brings, when the owner knows one.
    public var updateVersion: String?
    /// The host failed to load the app; Discover leaves it out.
    public var failed: Bool
    /// The source repository (extensions-in-git rows), when the owner sends one.
    public var repository: URL?

    /// The listing's one line: its tagline, else its summary.
    public var oneLine: String { tagline ?? summary }
    /// Verified publishers: first-party and Verified both show the check.
    public var publisherVerified: Bool { tier != .unverified }
    /// Whether Discover shows it: a store listing with a description that the host loaded.
    public var presentable: Bool { shelf == "store" && !summary.trimmingCharacters(in: .whitespaces).isEmpty && !failed }

    init?(json: AppJSON) {
        guard let id = json["app"]?.stringValue ?? json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        summary = json["summary"]?.stringValue ?? json["description"]?.stringValue ?? ""
        tagline = json["tagline"]?.stringValue.flatMap(Self.text)
        publisher = json["publisher"]?.stringValue ?? ""
        tier = json["tier"]?.stringValue.flatMap(AppStoreTier.init(rawValue:)) ?? .unverified
        version = json["version"]?.stringValue ?? ""
        icon = AppStoreIconRef(json["icon"])
        categories = json["categories"]?.arrayValue?.compactMap(\.stringValue) ?? []
        hideOnly = json["hide_only"]?.boolValue ?? (tier == .firstParty)
        shelf = json["shelf"]?.stringValue ?? "store"
        let install = json["install"]
        installed = install?["installed"]?.boolValue ?? false
        enabled = install?["enabled"]?.boolValue ?? installed
        hidden = install?["hidden"]?.boolValue ?? false
        updateVersion = AppStoreWire.updateVersion(install?["update"])
        failed = install?["failure"]?.stringValue.flatMap(Self.text) != nil
        repository = json["repository"]?.stringValue.flatMap(URL.init(string:))
    }

    /// A non-blank string, trimmed; nil otherwise.
    static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A permission a listing asks for, in plain words.
public nonisolated struct AppStoreScope: Sendable, Hashable, Identifiable {
    public var scope: String
    public var reason: String
    /// `standard`, `sensitive` or `restricted`.
    public var risk: String
    public var optional: Bool
    public var id: String { scope }
}

/// One place the app shows up in cmux (`contributes[]`).
public nonisolated struct AppStoreContribution: Sendable, Hashable {
    /// `section`, `sidebarWidget`, `statusItem`, `pane`, `newTab`, `sessionInfo` or `command`.
    public var kind: String
    public var title: String
}

/// One published version (`versions[]`).
public nonisolated struct AppStoreVersionRow: Sendable, Hashable, Identifiable {
    public var version: String
    /// The git tag of a repo extension's version (`v<version>`).
    public var tag: String?
    public var commit: String?
    public var date: Date?
    /// The cmux versions it runs on (`engines`), when the owner sends them.
    public var engines: String?
    public var yanked: Bool
    public var id: String { version }
}

/// One line of What's New: a merged pull request's title as the person reads it.
public nonisolated struct AppStoreChangeLine: Sendable, Hashable {
    public var title: String
    public var pr: Int?
}

/// `whats_new`: what the newest version changed.
public nonisolated struct AppStoreWhatsNew: Sendable, Hashable {
    public var version: String
    public var items: [AppStoreChangeLine]
}

/// `catalog.get`: a listing plus what its page shows.
public nonisolated struct AppStoreDetail: Sendable, Hashable, Identifiable {
    public var item: AppStoreItem
    public var scopes: [AppStoreScope]
    /// Package paths; each loads through `asset.get`.
    public var screenshots: [String]
    public var contributes: [AppStoreContribution]
    /// Newest first, as the owner orders them.
    public var versions: [AppStoreVersionRow]
    public var whatsNew: AppStoreWhatsNew?
    /// Machine kinds a deployed app's server runs on.
    public var deployTargets: [String]
    public var id: String { item.id }

    init?(json: AppJSON) {
        guard let item = AppStoreItem(json: json) else { return nil }
        self.item = item
        scopes = (json["scopes"]?.arrayValue ?? []).compactMap { row in
            guard let scope = row["scope"]?.stringValue else { return nil }
            return AppStoreScope(scope: scope, reason: row["reason"]?.stringValue ?? "",
                                 risk: row["risk"]?.stringValue ?? "standard", optional: row["optional"]?.boolValue ?? false)
        }
        screenshots = (json["screenshots"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        contributes = (json["contributes"]?.arrayValue ?? []).compactMap { row in
            guard let kind = row["kind"]?.stringValue, let title = row["title"]?.stringValue.flatMap(AppStoreItem.text) else { return nil }
            return AppStoreContribution(kind: kind, title: title)
        }
        versions = (json["versions"]?.arrayValue ?? []).compactMap { row in
            guard let version = row["version"]?.stringValue, !version.isEmpty else { return nil }
            let millis = row["date_ms"]?.numberValue ?? row["published_at_ms"]?.numberValue
            let date = millis.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? row["date"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
            return AppStoreVersionRow(version: version, tag: row["tag"]?.stringValue, commit: row["commit"]?.stringValue,
                                      date: date, engines: row["engines"]?.stringValue, yanked: row["yanked"]?.boolValue ?? false)
        }
        if let news = json["whats_new"], let lines = news["items"]?.arrayValue {
            let items = lines.compactMap { line -> AppStoreChangeLine? in
                guard let title = line["title"]?.stringValue.flatMap(AppStoreItem.text) else { return nil }
                return AppStoreChangeLine(title: title, pr: line["pr"]?.numberValue.flatMap { Int(exactly: $0) })
            }
            whatsNew = items.isEmpty ? nil : AppStoreWhatsNew(version: news["version"]?.stringValue ?? item.version, items: items)
        } else {
            whatsNew = nil
        }
        deployTargets = json["deploy"]?["targets"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// One shelf of the store (`catalog.sections` `sections[]`).
public nonisolated struct AppStoreSection: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case featured, category, chart, recent
    }

    public var id: String
    public var kind: Kind
    /// A string key the view resolves (never English from the owner).
    public var titleKey: String
    /// App ids, in the owner's order.
    public var apps: [String]
    /// The next page of this section, when the owner has more.
    public var nextCursor: String?

    init?(json: AppJSON) {
        guard let id = json["id"]?.stringValue, let kind = json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.id = id
        self.kind = kind
        titleKey = json["title_key"]?.stringValue ?? ""
        apps = json["apps"]?.arrayValue?.compactMap { $0.stringValue ?? $0["app"]?.stringValue } ?? []
        nextCursor = json["next_cursor"]?.stringValue
        ownerCategory = json["category"]?.stringValue
    }

    /// The owner's `category` field of a `category` section.
    private var ownerCategory: String?

    /// The category id of a `category` section: the owner's `category`, else the part of its id after
    /// `category:`, else its id.
    public var category: String? {
        guard kind == .category else { return nil }
        if let ownerCategory, !ownerCategory.isEmpty { return ownerCategory }
        return id.hasPrefix("category:") ? String(id.dropFirst("category:".count)) : id
    }
}

/// One installed app (`installed.list` `apps[]`).
public nonisolated struct AppStoreInstalledRow: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var tier: AppStoreTier
    public var hideOnly: Bool
    public var enabled: Bool
    public var hidden: Bool
    public var updateVersion: String?
    public var failure: String?

    init?(json: AppJSON) {
        guard let id = json["app"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        tier = json["tier"]?.stringValue.flatMap(AppStoreTier.init(rawValue:)) ?? .unverified
        hideOnly = json["hide_only"]?.boolValue ?? (tier == .firstParty)
        let state = json["state"]
        version = state?["version"]?.stringValue ?? ""
        enabled = state?["enabled"]?.boolValue ?? true
        hidden = state?["hidden"]?.boolValue ?? false
        updateVersion = AppStoreWire.updateVersion(state?["update"])
        failure = state?["failure"]?.stringValue.flatMap(AppStoreItem.text)
    }
}

/// One update the owner knows about (`updates.list` `updates[]`).
public nonisolated struct AppStoreUpdate: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var currentVersion: String?
    public var version: String
    public var failure: String?

    init?(json: AppJSON) {
        guard let id = json["app"]?.stringValue, let version = json["version"]?.stringValue else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        currentVersion = json["current_version"]?.stringValue
        self.version = version
        failure = json["failure"]?.stringValue.flatMap(AppStoreItem.text)
    }

    init(installed row: AppStoreInstalledRow, version: String) {
        id = row.id
        name = row.name
        currentVersion = row.version
        self.version = version
        failure = row.failure
    }
}

/// The op names and reply readers of the native store.
nonisolated enum AppStoreWire {
    static let catalogList = "apps.catalog.list"
    static let catalogGet = "apps.catalog.get"
    static let catalogSections = "apps.catalog.sections"
    static let installedList = "apps.installed.list"
    static let updatesList = "apps.updates.list"
    static let assetGet = "apps.asset.get"
    /// The owner's largest page; the store follows the cursor.
    static let pageSize = 200

    /// `install.update` is a string on the owner today and `{version}` in the page's draft: both read.
    static func updateVersion(_ json: AppJSON?) -> String? {
        (json?.stringValue ?? json?["version"]?.stringValue).flatMap(AppStoreItem.text)
    }

    /// One `catalog.list` page: its rows and the cursor of the next.
    static func catalogPage(_ json: AppJSON) -> (items: [AppStoreItem], next: String?) {
        ((json["listings"]?.arrayValue ?? []).compactMap(AppStoreItem.init(json:)), json["next_cursor"]?.stringValue)
    }

    static func sections(_ json: AppJSON) -> [AppStoreSection] {
        (json["sections"]?.arrayValue ?? []).compactMap(AppStoreSection.init(json:))
    }

    static func installed(_ json: AppJSON) -> [AppStoreInstalledRow] {
        (json["apps"]?.arrayValue ?? []).compactMap(AppStoreInstalledRow.init(json:))
    }

    static func updates(_ json: AppJSON) -> [AppStoreUpdate] {
        (json["updates"]?.arrayValue ?? []).compactMap(AppStoreUpdate.init(json:))
    }

    /// The image bytes of an `asset.get` reply (`data_url`, a base64 `data:image/...` URL); nil for anything else.
    static func assetData(_ json: AppJSON) -> Data? {
        guard let url = json["data_url"]?.stringValue, url.hasPrefix("data:image/"),
              let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }
}
