import CmuxNextCompat
import Foundation

extension BrowserSearchEngine {
    /// Chromium's prepopulated engine ids (`prepopulated_engines.json`) for
    /// the built-in engines it ships, so Chromium updates its own entry
    /// instead of adding a second one with the same keyword.
    private static let chromiumPrepopulateIDs = ["bing": 3, "duckduckgo": 92]

    /// Chromium's `default_search_provider_data.template_url_data` for this
    /// engine as JSON, or nil to keep Chromium's own default.
    ///
    /// Google is nil: Chromium's prepopulated Google (image search, its
    /// suggest parameters) is the same engine, so the shim resets the
    /// preference instead. An engine without a usable search address is
    /// nil too.
    var chromiumDefaultSearchJSON: String? {
        guard id != BrowserSearchEngine.google.id,
              let probe = searchURL(for: "cmux"), let scheme = probe.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = probe.host(), !host.isEmpty else { return nil }
        let keyword = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let data: [String: Any] = [
            "short_name": name,
            "keyword": keyword,
            "url": queryTemplate,
            "suggestions_url": suggestTemplate ?? "",
            "favicon_url": "\(scheme)://\(host)/favicon.ico",
            "input_encodings": ["UTF-8"],
            "prepopulate_id": Self.chromiumPrepopulateIDs[id] ?? 0,
            "safe_for_autoreplace": false,
            "synced_guid": "cmux-search-\(id)",
        ]
        guard let json = try? CheckedJSON(options: [.sortedKeys, .withoutEscapingSlashes]).data(data) else { return nil }
        return String(decoding: json, as: UTF8.self)
    }
}
