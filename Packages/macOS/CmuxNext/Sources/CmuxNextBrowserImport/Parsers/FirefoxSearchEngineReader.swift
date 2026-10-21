public import Foundation

/// Reads a Firefox profile's default search engine from `search.json.mozlz4`
/// (mozLz4, as the session store): the engine `metaData.defaultEngineId`
/// names (`metaData.current`, its name, in files before Firefox 97). An engine
/// the person added keeps its own addresses (`_urls`, the query `params`
/// joined on); one Firefox ships names only its id, so it maps to the
/// well-known engine's address. Nil when the file names no engine; only https
/// engines whose search address takes the typed text are returned.
public struct FirefoxSearchEngineReader {
    public init() {}

    public func read(profile: URL) -> ImportedSearchEngine? {
        guard let data = FileManager.default.contents(atPath: profile.appending(path: "search.json.mozlz4").path),
              let json = FirefoxSessionReader().decompress(data) else { return nil }
        return parse(json)
    }

    func parse(_ json: Data) -> ImportedSearchEngine? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let engines = root["engines"] as? [[String: Any]] else { return nil }
        let meta = root["metaData"] as? [String: Any]
        let engine: [String: Any]?
        if let id = meta?["defaultEngineId"] as? String, !id.isEmpty {
            engine = engines.first { $0["id"] as? String == id }
        } else if let name = meta?["current"] as? String, !name.isEmpty {
            engine = engines.first { $0["_name"] as? String == name }
        } else {
            return nil
        }
        guard let engine else { return nil }
        let name = engine["_name"] as? String
        let urls = engine["_urls"] as? [[String: Any]] ?? []
        let page = urls.first { ($0["type"] as? String ?? "text/html") == "text/html" }.flatMap(Self.template)
        guard let page else { return ImportedSearchEngine.wellKnown(named: [engine["id"] as? String, name]) }
        let suggest = urls.first { $0["type"] as? String == "application/x-suggestions+json" }.flatMap(Self.template)
        let keyword = engine["_definedAliases"].flatMap { ($0 as? [String])?.first } ?? (engine["alias"] as? String)
        return ChromiumSearchEngineReader.engine(name: name, keyword: keyword, search: page, suggest: suggest)
    }

    /// An `_urls` entry's address with its `params` (`{"name":"q","value":"{searchTerms}"}`) in the query.
    static func template(_ entry: [String: Any]) -> String? {
        guard let template = entry["template"] as? String else { return nil }
        let params = (entry["params"] as? [[String: Any]] ?? []).compactMap { param -> String? in
            guard let name = param["name"] as? String, let value = param["value"] as? String else { return nil }
            return "\(name)=\(value)"
        }
        guard !params.isEmpty else { return template }
        return template + (template.contains("?") ? "&" : "?") + params.joined(separator: "&")
    }
}
