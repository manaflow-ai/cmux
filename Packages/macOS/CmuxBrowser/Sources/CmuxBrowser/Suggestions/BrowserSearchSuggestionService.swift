import Foundation
public import CmuxSettings

/// Fetches remote address-bar search suggestions from a search engine's
/// autosuggest endpoint.
///
/// The service is stateless: it owns no mutable storage and only performs
/// short-timeout network requests against the engine-specific suggestion API,
/// switching response parsing on `BrowserSearchEngine`. Google requests fan out
/// to DuckDuckGo and Bing fallbacks in parallel because Google's endpoint can
/// intermittently throttle app-style traffic. A deterministic UI-test override
/// (`CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON`) short-circuits the network path.
public actor BrowserSearchSuggestionService {
    /// Creates a suggestion service. The service holds no state, so a fresh
    /// instance is constructed by the owner that needs it (no shared singleton).
    public init() {}

    /// Returns remote suggestions for `query` using `engine`.
    ///
    /// - Parameters:
    ///   - engine: The search engine whose autosuggest endpoint to query.
    ///   - query: The raw address-bar text; trimmed before use, empty yields `[]`.
    /// - Returns: Suggestion strings, or `[]` when the query is empty, the
    ///   engine has no suggestion endpoint, or the request fails.
    public func suggestions(engine: BrowserSearchEngine, query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Deterministic UI-test hook for validating remote suggestion rendering
        // without relying on external network behavior.
        let forced = ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"]
            ?? UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON")
        if let forced,
           let data = forced.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return parsed.compactMap { item in
                guard let s = item as? String else { return nil }
                let value = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }

        // Google's endpoint can intermittently throttle/block app-style traffic.
        // Query fallbacks in parallel so we can show predictions quickly.
        if engine == .google {
            return await fetchRemoteSuggestionsWithGoogleFallbacks(query: trimmed)
        }

        return await fetchRemoteSuggestions(engine: engine, query: trimmed)
    }

    private func fetchRemoteSuggestionsWithGoogleFallbacks(query: String) async -> [String] {
        await withTaskGroup(of: [String].self, returning: [String].self) { group in
            group.addTask {
                await self.fetchRemoteSuggestions(engine: .google, query: query)
            }
            group.addTask {
                await self.fetchRemoteSuggestions(engine: .duckduckgo, query: query)
            }
            group.addTask {
                await self.fetchRemoteSuggestions(engine: .bing, query: query)
            }

            while let result = await group.next() {
                if !result.isEmpty {
                    group.cancelAll()
                    return result
                }
            }

            return []
        }
    }

    private func fetchRemoteSuggestions(engine: BrowserSearchEngine, query: String) async -> [String] {
        let url: URL?
        switch engine {
        case .google:
            var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")
            c?.queryItems = [
                URLQueryItem(name: "client", value: "firefox"),
                URLQueryItem(name: "q", value: query),
            ]
            url = c?.url
        case .duckduckgo:
            var c = URLComponents(string: "https://duckduckgo.com/ac/")
            c?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "list"),
            ]
            url = c?.url
        case .bing:
            var c = URLComponents(string: "https://www.bing.com/osjson.aspx")
            c?.queryItems = [
                URLQueryItem(name: "query", value: query),
            ]
            url = c?.url
        case .kagi:
            var c = URLComponents(string: "https://kagi.com/api/autosuggest")
            c?.queryItems = [
                URLQueryItem(name: "q", value: query),
            ]
            url = c?.url
        case .startpage:
            var c = URLComponents(string: "https://www.startpage.com/osuggestions")
            c?.queryItems = [
                URLQueryItem(name: "q", value: query),
            ]
            url = c?.url
        case .brave, .perplexity, .exa, .yahoo, .ecosia, .qwant, .mojeek, .wikipedia, .github, .baidu, .yandex, .custom:
            url = nil
        }

        guard let url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 0.65
        req.cachePolicy = .returnCacheDataElseLoad
        req.setValue(String.safariDesktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            return []
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }

        switch engine {
        case .google, .bing, .kagi, .startpage:
            return parseOSJSON(data: data)
        case .duckduckgo:
            return parseDuckDuckGo(data: data)
        case .brave, .perplexity, .exa, .yahoo, .ecosia, .qwant, .mojeek, .wikipedia, .github, .baidu, .yandex, .custom:
            return []
        }
    }

    private func parseOSJSON(data: Data) -> [String] {
        // Format: [query, [suggestions...], ...]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2,
              let list = root[1] as? [Any] else {
            return []
        }
        var out: [String] = []
        out.reserveCapacity(list.count)
        for item in list {
            guard let s = item as? String else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
        }
        return out
    }

    private func parseDuckDuckGo(data: Data) -> [String] {
        // Format: [{phrase:"..."}, ...]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var out: [String] = []
        out.reserveCapacity(root.count)
        for item in root {
            guard let dict = item as? [String: Any],
                  let phrase = dict["phrase"] as? String else { continue }
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
        }
        return out
    }
}
