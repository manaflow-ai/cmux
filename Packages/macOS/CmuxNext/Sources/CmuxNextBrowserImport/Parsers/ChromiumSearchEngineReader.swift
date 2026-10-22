public import Foundation

/// A source profile's default search engine: Chromium's name, keyword and
/// address templates (`{searchTerms}` marks the typed text).
public struct ImportedSearchEngine: Sendable, Codable, Equatable {
    public var name: String
    public var keyword: String?
    public var search: String
    public var suggest: String?

    public init(name: String, keyword: String? = nil, search: String, suggest: String? = nil) {
        self.name = name
        self.keyword = keyword
        self.search = search
        self.suggest = suggest
    }

    /// What `browser.searchEngine` becomes: the built-in engine whose search
    /// address has this engine's host (`builtIn`: engine id to its search
    /// template), else `custom` with this engine's addresses.
    public func setting(builtIn: [String: String]) -> (engine: String, search: String?, suggest: String?) {
        let host = Self.host(search)
        if let host, let match = builtIn.first(where: { Self.host($0.value) == host }) { return (match.key, nil, nil) }
        return ("custom", search, suggest)
    }

    static func host(_ template: String) -> String? {
        let url = URL(string: template.replacingOccurrences(of: "{searchTerms}", with: "x").replacingOccurrences(of: "%s", with: "x"))
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Reads a Chromium profile's default search engine: `Preferences`'
/// `default_search_provider_data.template_url_data` (an engine the person
/// set), else the `keywords` row of `Web Data` whose `sync_guid` is
/// `default_search_provider.guid`. Nil when the profile keeps the browser's
/// own default; only https engines whose search address takes the typed text
/// are returned (Chromium-only `{google:...}` parameters are dropped).
public struct ChromiumSearchEngineReader {
    public init() {}

    public func read(profile: URL) -> ImportedSearchEngine? {
        guard let data = FileManager.default.contents(atPath: profile.appending(path: "Preferences").path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let template = (root["default_search_provider_data"] as? [String: Any])?["template_url_data"] as? [String: Any],
           let engine = Self.engine(name: template["short_name"] as? String, keyword: template["keyword"] as? String,
                                    search: template["url"] as? String, suggest: template["suggestions_url"] as? String) {
            return engine
        }
        guard let guid = (root["default_search_provider"] as? [String: Any])?["guid"] as? String, !guid.isEmpty,
              let database = try? SQLiteSnapshot(copying: profile.appending(path: "Web Data")) else { return nil }
        var found: ImportedSearchEngine?
        let quoted = guid.replacingOccurrences(of: "'", with: "''")
        try? database.query("SELECT short_name, keyword, url, suggest_url FROM keywords WHERE sync_guid = '\(quoted)' LIMIT 1") { row in
            found = Self.engine(name: row.string(0), keyword: row.string(1), search: row.string(2), suggest: row.string(3))
            return false
        }
        return found
    }

    static func engine(name: String?, keyword: String?, search: String?, suggest: String?) -> ImportedSearchEngine? {
        guard let search = search.map(clean), search.contains("{searchTerms}"), search.lowercased().hasPrefix("https://") else { return nil }
        let suggest = suggest.map(clean).flatMap { $0.contains("{searchTerms}") && $0.lowercased().hasPrefix("https://") ? $0 : nil }
        let title = name.flatMap { $0.isEmpty ? nil : $0 } ?? ImportedSearchEngine.host(search) ?? search
        return ImportedSearchEngine(name: title, keyword: keyword.flatMap { $0.isEmpty ? nil : $0 }, search: search, suggest: suggest)
    }

    /// Drops Chromium's own `{google:...}` parameters and other placeholders
    /// (`{inputEncoding}`), which no other browser fills in, and any query
    /// item they leave empty (`&t=`).
    static func clean(_ template: String) -> String {
        let text = template.replacingOccurrences(of: #"\{google:[A-Za-z]+\}"#, with: "", options: .regularExpression)
        guard var parts = URLComponents(string: text.replacingOccurrences(of: "{searchTerms}", with: "CMUXSEARCHTERMS")),
              let items = parts.queryItems else { return text }
        let kept = items.filter { item in
            guard let value = item.value else { return !item.name.isEmpty }
            return !value.isEmpty && !value.contains("{")
        }
        parts.queryItems = kept.isEmpty ? nil : kept
        return (parts.string ?? text).replacingOccurrences(of: "CMUXSEARCHTERMS", with: "{searchTerms}")
    }
}
