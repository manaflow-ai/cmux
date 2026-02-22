import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import SQLite3

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckduckgo
    case bing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components: URLComponents?
        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")
        case .duckduckgo:
            components = URLComponents(string: "https://duckduckgo.com/")
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")
        }

        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
        ]
        return components?.url
    }
}

enum BrowserSearchSettings {
    static let searchEngineKey = "browserSearchEngine"
    static let searchSuggestionsEnabledKey = "browserSearchSuggestionsEnabled"
    static let defaultSearchEngine: BrowserSearchEngine = .google
    static let defaultSearchSuggestionsEnabled: Bool = true

    static func currentSearchEngine(defaults: UserDefaults = .standard) -> BrowserSearchEngine {
        guard let raw = defaults.string(forKey: searchEngineKey),
              let engine = BrowserSearchEngine(rawValue: raw) else {
            return defaultSearchEngine
        }
        return engine
    }

    static func currentSearchSuggestionsEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Mirror @AppStorage behavior: bool(forKey:) returns false if key doesn't exist.
        // Default to enabled unless user explicitly set a value.
        if defaults.object(forKey: searchSuggestionsEnabledKey) == nil {
            return defaultSearchSuggestionsEnabled
        }
        return defaults.bool(forKey: searchSuggestionsEnabledKey)
    }
}

enum BrowserForcedDarkModeSettings {
    static let enabledKey = "browserForcedDarkModeEnabled"
    static let opacityKey = "browserForcedDarkModeOpacity"
    static let defaultEnabled: Bool = false
    static let defaultOpacity: Double = 45
    static let minOpacity: Double = 5
    static let maxOpacity: Double = 90

    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func opacity(defaults: UserDefaults = .standard) -> Double {
        if defaults.object(forKey: opacityKey) == nil {
            return defaultOpacity
        }
        return normalizedOpacity(defaults.double(forKey: opacityKey))
    }

    static func normalizedOpacity(_ rawValue: Double) -> Double {
        guard rawValue.isFinite else { return defaultOpacity }
        return min(maxOpacity, max(minOpacity, rawValue))
    }
}

enum BrowserLinkOpenSettings {
    static let openTerminalLinksInCmuxBrowserKey = "browserOpenTerminalLinksInCmuxBrowser"
    static let defaultOpenTerminalLinksInCmuxBrowser: Bool = true

    static let browserHostWhitelistKey = "browserHostWhitelist"
    static let defaultBrowserHostWhitelist: String = ""

    static func openTerminalLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) == nil {
            return defaultOpenTerminalLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
    }

    static func hostWhitelist(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserHostWhitelistKey) ?? defaultBrowserHostWhitelist
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Check whether a hostname matches the configured whitelist.
    /// Empty whitelist means "allow all" (no filtering).
    /// Supports exact match and wildcard prefix (`*.example.com`).
    static func hostMatchesWhitelist(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        let rawPatterns = hostWhitelist(defaults: defaults)
        if rawPatterns.isEmpty { return true }
        guard let normalizedHost = BrowserInsecureHTTPSettings.normalizeHost(host) else { return false }
        for rawPattern in rawPatterns {
            guard let pattern = normalizeWhitelistPattern(rawPattern) else { continue }
            if hostMatchesPattern(normalizedHost, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private static func normalizeWhitelistPattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = BrowserInsecureHTTPSettings.normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return BrowserInsecureHTTPSettings.normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }
}

enum BrowserInsecureHTTPSettings {
    static let allowlistKey = "browserInsecureHTTPAllowlist"
    static let defaultAllowlistPatterns = [
        "localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "*.localtest.me",
    ]
    static let defaultAllowlistText = defaultAllowlistPatterns.joined(separator: "\n")

    static func normalizedAllowlistPatterns(defaults: UserDefaults = .standard) -> [String] {
        normalizedAllowlistPatterns(rawValue: defaults.string(forKey: allowlistKey))
    }

    static func normalizedAllowlistPatterns(rawValue: String?) -> [String] {
        let source: String
        if let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = rawValue
        } else {
            source = defaultAllowlistText
        }
        let parsed = parsePatterns(from: source)
        return parsed.isEmpty ? defaultAllowlistPatterns : parsed
    }

    static func isHostAllowed(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        isHostAllowed(host, rawAllowlist: defaults.string(forKey: allowlistKey))
    }

    static func isHostAllowed(_ host: String, rawAllowlist: String?) -> Bool {
        guard let normalizedHost = normalizeHost(host) else { return false }
        return normalizedAllowlistPatterns(rawValue: rawAllowlist).contains { pattern in
            hostMatchesPattern(normalizedHost, pattern: pattern)
        }
    }

    static func addAllowedHost(_ host: String, defaults: UserDefaults = .standard) {
        guard let normalizedHost = normalizeHost(host) else { return }
        var patterns = normalizedAllowlistPatterns(defaults: defaults)
        guard !patterns.contains(normalizedHost) else { return }
        patterns.append(normalizedHost)
        defaults.set(patterns.joined(separator: "\n"), forKey: allowlistKey)
    }

    static func normalizeHost(_ rawHost: String) -> String? {
        var value = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }

        if let parsed = URL(string: value)?.host {
            return trimHost(parsed)
        }

        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }

        if let slash = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<slash])
        }

        if value.hasPrefix("[") {
            if let closing = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex)..<closing])
            } else {
                value.removeFirst()
            }
        } else if let colon = value.lastIndex(of: ":"),
                  value[value.index(after: colon)...].allSatisfy(\.isNumber),
                  value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }

        return trimHost(value)
    }

    private static func parsePatterns(from rawValue: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n\r\t")
        var out: [String] = []
        var seen = Set<String>()
        for token in rawValue.components(separatedBy: separators) {
            guard let normalized = normalizePattern(token) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    private static func normalizePattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private static func trimHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }

        // Canonicalize IDN entries (e.g. bücher.example -> xn--bcher-kva.example)
        // so user-entered allowlist patterns compare against URL.host consistently.
        if let canonicalized = URL(string: "https://\(trimmed)")?.host {
            return canonicalized
        }

        return trimmed
    }
}

func browserShouldBlockInsecureHTTPURL(
    _ url: URL,
    defaults: UserDefaults = .standard
) -> Bool {
    browserShouldBlockInsecureHTTPURL(
        url,
        rawAllowlist: defaults.string(forKey: BrowserInsecureHTTPSettings.allowlistKey)
    )
}

func browserShouldBlockInsecureHTTPURL(
    _ url: URL,
    rawAllowlist: String?
) -> Bool {
    guard url.scheme?.lowercased() == "http" else { return false }
    guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return true }
    return !BrowserInsecureHTTPSettings.isHostAllowed(host, rawAllowlist: rawAllowlist)
}

func browserShouldConsumeOneTimeInsecureHTTPBypass(
    _ url: URL,
    bypassHostOnce: inout String?
) -> Bool {
    guard let bypassHost = bypassHostOnce else { return false }
    guard url.scheme?.lowercased() == "http",
          let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
        return false
    }
    guard host == bypassHost else { return false }
    bypassHostOnce = nil
    return true
}

func browserShouldPersistInsecureHTTPAllowlistSelection(
    response: NSApplication.ModalResponse,
    suppressionEnabled: Bool
) -> Bool {
    guard suppressionEnabled else { return false }
    return response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
}

func browserPreparedNavigationRequest(_ request: URLRequest) -> URLRequest {
    var preparedRequest = request
    // Match browser behavior for ordinary loads while preserving method/body/headers.
    preparedRequest.cachePolicy = .useProtocolCachePolicy
    return preparedRequest
}

enum BrowserUserAgentSettings {
    // Force a Safari UA. Some WebKit builds return a minimal UA without Version/Safari tokens,
    // and some installs may have legacy Chrome UA overrides. Both can cause Google to serve
    // fallback/old UIs or trigger bot checks.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"
}

func normalizedBrowserHistoryNamespace(bundleIdentifier: String) -> String {
    if bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.") {
        return "com.cmuxterm.app.debug"
    }
    if bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.") {
        return "com.cmuxterm.app.staging"
    }
    return bundleIdentifier
}

@MainActor
final class BrowserHistoryStore: ObservableObject {
    static let shared = BrowserHistoryStore()

    struct Entry: Codable, Identifiable, Hashable {
        let id: UUID
        var url: String
        var title: String?
        var lastVisited: Date
        var visitCount: Int
        var typedCount: Int
        var lastTypedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id
            case url
            case title
            case lastVisited
            case visitCount
            case typedCount
            case lastTypedAt
        }

        init(
            id: UUID,
            url: String,
            title: String?,
            lastVisited: Date,
            visitCount: Int,
            typedCount: Int = 0,
            lastTypedAt: Date? = nil
        ) {
            self.id = id
            self.url = url
            self.title = title
            self.lastVisited = lastVisited
            self.visitCount = visitCount
            self.typedCount = typedCount
            self.lastTypedAt = lastTypedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            url = try container.decode(String.self, forKey: .url)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            lastVisited = try container.decode(Date.self, forKey: .lastVisited)
            visitCount = try container.decode(Int.self, forKey: .visitCount)
            typedCount = try container.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
            lastTypedAt = try container.decodeIfPresent(Date.self, forKey: .lastTypedAt)
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let fileURL: URL?
    private var didLoad: Bool = false
    private var saveTask: Task<Void, Never>?
    private let maxEntries: Int = 5000
    private let saveDebounceNanoseconds: UInt64 = 120_000_000

    private struct SuggestionCandidate {
        let entry: Entry
        let urlLower: String
        let urlSansSchemeLower: String
        let hostLower: String
        let pathAndQueryLower: String
        let titleLower: String
    }

    private struct ScoredSuggestion {
        let entry: Entry
        let score: Double
    }

    init(fileURL: URL? = nil) {
        // Avoid calling @MainActor-isolated static methods from default argument context.
        self.fileURL = fileURL ?? BrowserHistoryStore.defaultHistoryFileURL()
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let fileURL else { return }
        migrateLegacyTaggedHistoryFileIfNeeded(to: fileURL)

        // Load synchronously on first access so the first omnibar query can use
        // persisted history immediately (important for deterministic UI behavior).
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return
        }

        let decoded: [Entry]
        do {
            decoded = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            return
        }

        // Most-recent first.
        entries = decoded.sorted(by: { $0.lastVisited > $1.lastVisited })

        // Remove entries with invalid hosts (no TLD), e.g. "https://news."
        let beforeCount = entries.count
        entries.removeAll { entry in
            guard let url = URL(string: entry.url),
                  let host = url.host?.lowercased() else { return false }
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            return !trimmed.contains(".")
        }
        if entries.count != beforeCount {
            scheduleSave()
        }
    }

    func recordVisit(url: URL?, title: String?) {
        loadIfNeeded()

        guard let url else { return }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // Skip URLs whose host lacks a TLD (e.g. "https://news.").
        if let host = url.host?.lowercased() {
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmed.contains(".") { return }
        }

        let urlString = url.absoluteString
        guard urlString != "about:blank" else { return }
        let normalizedKey = normalizedHistoryKey(url: url)

        if let idx = entries.firstIndex(where: {
            if $0.url == urlString { return true }
            return normalizedHistoryKey(urlString: $0.url) == normalizedKey
        }) {
            entries[idx].lastVisited = Date()
            entries[idx].visitCount += 1
            // Prefer non-empty titles, but don't clobber an existing title with empty/whitespace.
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries[idx].title = title
            }
        } else {
            entries.insert(Entry(
                id: UUID(),
                url: urlString,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                lastVisited: Date(),
                visitCount: 1
            ), at: 0)
        }

        // Keep most-recent first and bound size.
        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        scheduleSave()
    }

    func recordTypedNavigation(url: URL?) {
        loadIfNeeded()

        guard let url else { return }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // Skip URLs whose host lacks a TLD (e.g. "https://news.").
        if let host = url.host?.lowercased() {
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmed.contains(".") { return }
        }

        let urlString = url.absoluteString
        guard urlString != "about:blank" else { return }

        let now = Date()
        let normalizedKey = normalizedHistoryKey(url: url)
        if let idx = entries.firstIndex(where: {
            if $0.url == urlString { return true }
            return normalizedHistoryKey(urlString: $0.url) == normalizedKey
        }) {
            entries[idx].typedCount += 1
            entries[idx].lastTypedAt = now
            entries[idx].lastVisited = now
        } else {
            entries.insert(Entry(
                id: UUID(),
                url: urlString,
                title: nil,
                lastVisited: now,
                visitCount: 1,
                typedCount: 1,
                lastTypedAt: now
            ), at: 0)
        }

        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        scheduleSave()
    }

    func suggestions(for input: String, limit: Int = 10) -> [Entry] {
        loadIfNeeded()
        guard limit > 0 else { return [] }

        let q = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let queryTokens = tokenizeSuggestionQuery(q)
        let now = Date()

        let matched = entries.compactMap { entry -> ScoredSuggestion? in
            let candidate = makeSuggestionCandidate(entry: entry)
            guard let score = suggestionScore(candidate: candidate, query: q, queryTokens: queryTokens, now: now) else {
                return nil
            }
            return ScoredSuggestion(entry: entry, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.lastVisited != rhs.entry.lastVisited { return lhs.entry.lastVisited > rhs.entry.lastVisited }
            if lhs.entry.visitCount != rhs.entry.visitCount { return lhs.entry.visitCount > rhs.entry.visitCount }
            return lhs.entry.url < rhs.entry.url
        }

        if matched.count <= limit { return matched.map(\.entry) }
        return Array(matched.prefix(limit).map(\.entry))
    }

    func recentSuggestions(limit: Int = 10) -> [Entry] {
        loadIfNeeded()
        guard limit > 0 else { return [] }

        let ranked = entries.sorted { lhs, rhs in
            if lhs.typedCount != rhs.typedCount { return lhs.typedCount > rhs.typedCount }
            let lhsTypedDate = lhs.lastTypedAt ?? .distantPast
            let rhsTypedDate = rhs.lastTypedAt ?? .distantPast
            if lhsTypedDate != rhsTypedDate { return lhsTypedDate > rhsTypedDate }
            if lhs.lastVisited != rhs.lastVisited { return lhs.lastVisited > rhs.lastVisited }
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return lhs.url < rhs.url
        }

        if ranked.count <= limit { return ranked }
        return Array(ranked.prefix(limit))
    }

    @discardableResult
    func mergeImportedEntries(_ importedEntries: [Entry]) -> Int {
        loadIfNeeded()
        guard !importedEntries.isEmpty else { return 0 }

        var mergedCount = 0
        for imported in importedEntries {
            guard let parsedURL = URL(string: imported.url),
                  let scheme = parsedURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }

            if let host = parsedURL.host?.lowercased() {
                let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
                if !trimmed.contains(".") { continue }
            }

            let urlString = parsedURL.absoluteString
            guard urlString != "about:blank" else { continue }
            let normalizedKey = normalizedHistoryKey(url: parsedURL)

            let importedTitle = imported.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let importedLastVisited = imported.lastVisited
            let importedVisitCount = max(1, imported.visitCount)
            let importedTypedCount = max(0, imported.typedCount)
            let importedLastTypedAt = imported.lastTypedAt

            if let idx = entries.firstIndex(where: {
                if $0.url == urlString { return true }
                guard let normalizedKey else { return false }
                return normalizedHistoryKey(urlString: $0.url) == normalizedKey
            }) {
                var didMutate = false
                if importedLastVisited > entries[idx].lastVisited {
                    entries[idx].lastVisited = importedLastVisited
                    didMutate = true
                }
                if importedVisitCount > entries[idx].visitCount {
                    entries[idx].visitCount = importedVisitCount
                    didMutate = true
                }
                if importedTypedCount > entries[idx].typedCount {
                    entries[idx].typedCount = importedTypedCount
                    didMutate = true
                }
                if let importedLastTypedAt {
                    if let existingLastTypedAt = entries[idx].lastTypedAt {
                        if importedLastTypedAt > existingLastTypedAt {
                            entries[idx].lastTypedAt = importedLastTypedAt
                            didMutate = true
                        }
                    } else {
                        entries[idx].lastTypedAt = importedLastTypedAt
                        didMutate = true
                    }
                }

                let existingTitle = entries[idx].title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let incomingTitle = importedTitle ?? ""
                if !incomingTitle.isEmpty,
                   (existingTitle.isEmpty || importedLastVisited >= entries[idx].lastVisited) {
                    if entries[idx].title != incomingTitle {
                        entries[idx].title = incomingTitle
                        didMutate = true
                    }
                }

                if didMutate {
                    mergedCount += 1
                }
            } else {
                entries.append(Entry(
                    id: UUID(),
                    url: urlString,
                    title: importedTitle,
                    lastVisited: importedLastVisited,
                    visitCount: importedVisitCount,
                    typedCount: importedTypedCount,
                    lastTypedAt: importedLastTypedAt
                ))
                mergedCount += 1
            }
        }

        guard mergedCount > 0 else { return 0 }
        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        scheduleSave()
        return mergedCount
    }

    func clearHistory() {
        loadIfNeeded()
        saveTask?.cancel()
        saveTask = nil
        entries = []
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    func removeHistoryEntry(urlString: String) -> Bool {
        loadIfNeeded()
        let normalized = normalizedHistoryKey(urlString: urlString)
        let originalCount = entries.count
        entries.removeAll { entry in
            if entry.url == urlString { return true }
            guard let normalized else { return false }
            return normalizedHistoryKey(urlString: entry.url) == normalized
        }
        let didRemove = entries.count != originalCount
        if didRemove {
            scheduleSave()
        }
        return didRemove
    }

    func flushPendingSaves() {
        loadIfNeeded()
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        try? Self.persistSnapshot(entries, to: fileURL)
    }

    private func scheduleSave() {
        guard let fileURL else { return }

        saveTask?.cancel()
        let snapshot = entries
        let debounceNanoseconds = saveDebounceNanoseconds

        saveTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds) // debounce
            } catch {
                return
            }
            if Task.isCancelled { return }

            do {
                try Self.persistSnapshot(snapshot, to: fileURL)
            } catch {
                return
            }
        }
    }

    private func migrateLegacyTaggedHistoryFileIfNeeded(to targetURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: targetURL.path) else { return }
        guard let legacyURL = Self.legacyTaggedHistoryFileURL(),
              legacyURL != targetURL,
              fm.fileExists(atPath: legacyURL.path) else {
            return
        }

        do {
            let dir = targetURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            try fm.copyItem(at: legacyURL, to: targetURL)
        } catch {
            return
        }
    }

    private func makeSuggestionCandidate(entry: Entry) -> SuggestionCandidate {
        let urlLower = entry.url.lowercased()
        let urlSansSchemeLower = stripHTTPSSchemePrefix(urlLower)
        let components = URLComponents(string: entry.url)
        let hostLower = components?.host?.lowercased() ?? ""
        let path = (components?.percentEncodedPath ?? components?.path ?? "").lowercased()
        let query = (components?.percentEncodedQuery ?? components?.query ?? "").lowercased()
        let pathAndQueryLower: String
        if query.isEmpty {
            pathAndQueryLower = path
        } else {
            pathAndQueryLower = "\(path)?\(query)"
        }
        let titleLower = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SuggestionCandidate(
            entry: entry,
            urlLower: urlLower,
            urlSansSchemeLower: urlSansSchemeLower,
            hostLower: hostLower,
            pathAndQueryLower: pathAndQueryLower,
            titleLower: titleLower
        )
    }

    private func suggestionScore(
        candidate: SuggestionCandidate,
        query: String,
        queryTokens: [String],
        now: Date
    ) -> Double? {
        let queryIncludesScheme = query.hasPrefix("http://") || query.hasPrefix("https://")
        let urlMatchValue = queryIncludesScheme ? candidate.urlLower : candidate.urlSansSchemeLower
        let isSingleCharacterQuery = query.count == 1
        if isSingleCharacterQuery {
            let hasSingleCharStrongMatch =
                candidate.hostLower.hasPrefix(query) ||
                candidate.titleLower.hasPrefix(query) ||
                urlMatchValue.hasPrefix(query)
            guard hasSingleCharStrongMatch else { return nil }
        }

        let queryMatches =
            urlMatchValue.contains(query) ||
            candidate.hostLower.contains(query) ||
            candidate.pathAndQueryLower.contains(query) ||
            candidate.titleLower.contains(query)

        let tokenMatches = !queryTokens.isEmpty && queryTokens.allSatisfy { token in
            candidate.urlSansSchemeLower.contains(token) ||
            candidate.hostLower.contains(token) ||
            candidate.pathAndQueryLower.contains(token) ||
            candidate.titleLower.contains(token)
        }

        guard queryMatches || tokenMatches else { return nil }

        var score = 0.0

        if urlMatchValue == query { score += 1200 }
        if candidate.hostLower == query { score += 980 }
        if candidate.hostLower.hasPrefix(query) { score += 680 }
        if urlMatchValue.hasPrefix(query) { score += 560 }
        if candidate.titleLower.hasPrefix(query) { score += 420 }
        if candidate.pathAndQueryLower.hasPrefix(query) { score += 300 }

        if candidate.hostLower.contains(query) { score += 210 }
        if candidate.pathAndQueryLower.contains(query) { score += 165 }
        if candidate.titleLower.contains(query) { score += 145 }

        for token in queryTokens {
            if candidate.hostLower == token { score += 260 }
            else if candidate.hostLower.hasPrefix(token) { score += 170 }
            else if candidate.hostLower.contains(token) { score += 110 }

            if candidate.pathAndQueryLower.hasPrefix(token) { score += 80 }
            else if candidate.pathAndQueryLower.contains(token) { score += 52 }

            if candidate.titleLower.hasPrefix(token) { score += 74 }
            else if candidate.titleLower.contains(token) { score += 48 }
        }

        // Blend recency and repeat visits so history feels closer to browser frecency.
        let ageHours = max(0, now.timeIntervalSince(candidate.entry.lastVisited) / 3600)
        let recencyScore = max(0, 110 - (ageHours / 3))
        let frequencyScore = min(120, log1p(Double(max(1, candidate.entry.visitCount))) * 38)
        let typedFrequencyScore = min(190, log1p(Double(max(0, candidate.entry.typedCount))) * 80)
        let typedRecencyScore: Double
        if let lastTypedAt = candidate.entry.lastTypedAt {
            let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
            typedRecencyScore = max(0, 85 - (typedAgeHours / 4))
        } else {
            typedRecencyScore = 0
        }
        score += recencyScore + frequencyScore + typedFrequencyScore + typedRecencyScore

        return score
    }

    private func stripHTTPSSchemePrefix(_ value: String) -> String {
        if value.hasPrefix("https://") {
            return String(value.dropFirst("https://".count))
        }
        if value.hasPrefix("http://") {
            return String(value.dropFirst("http://".count))
        }
        return value
    }

    private func normalizedHistoryKey(url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        return normalizedHistoryKey(components: &components)
    }

    private func normalizedHistoryKey(urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else { return nil }
        return normalizedHistoryKey(components: &components)
    }

    private func normalizedHistoryKey(components: inout URLComponents) -> String? {
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased() else {
            return nil
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }

        let portPart: String
        if let port = components.port {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let queryPart: String
        if let query = components.percentEncodedQuery, !query.isEmpty {
            queryPart = "?\(query.lowercased())"
        } else {
            queryPart = ""
        }

        return "\(scheme)://\(host)\(portPart)\(path)\(queryPart)"
    }

    private func tokenizeSuggestionQuery(_ query: String) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        for raw in query.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    nonisolated private static func defaultHistoryFileURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let namespace = normalizedBrowserHistoryNamespace(bundleIdentifier: bundleId)
        let dir = appSupport.appendingPathComponent(namespace, isDirectory: true)
        return dir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    nonisolated private static func legacyTaggedHistoryFileURL() -> URL? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let namespace = normalizedBrowserHistoryNamespace(bundleIdentifier: bundleId)
        guard namespace != bundleId else { return nil }
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent(bundleId, isDirectory: true)
        return dir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    nonisolated private static func persistSnapshot(_ snapshot: [Entry], to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}

actor BrowserSearchSuggestionService {
    static let shared = BrowserSearchSuggestionService()

    func suggestions(engine: BrowserSearchEngine, query: String) async -> [String] {
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
        }

        guard let url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 0.65
        req.cachePolicy = .returnCacheDataElseLoad
        req.setValue(BrowserUserAgentSettings.safariUserAgent, forHTTPHeaderField: "User-Agent")
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
        case .google, .bing:
            return parseOSJSON(data: data)
        case .duckduckgo:
            return parseDuckDuckGo(data: data)
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

/// BrowserPanel provides a WKWebView-based browser panel.
/// All browser panels share a WKProcessPool for cookie sharing.
private enum BrowserInsecureHTTPNavigationIntent {
    case currentTab
    case newTab
}

@MainActor
final class BrowserPanel: Panel, ObservableObject {
    /// Shared process pool for cookie sharing across all browser panels
    private static let sharedProcessPool = WKProcessPool()

    private static func clampedGhosttyBackgroundOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    private static func isDarkAppearance(
        appAppearance: NSAppearance? = NSApp?.effectiveAppearance
    ) -> Bool {
        guard let appAppearance else { return false }
        return appAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func resolvedGhosttyBackgroundColor(from notification: Notification? = nil) -> NSColor {
        let userInfo = notification?.userInfo
        let baseColor = (userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)
            ?? GhosttyApp.shared.defaultBackgroundColor

        let opacity: Double
        if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? Double {
            opacity = value
        } else if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? NSNumber {
            opacity = value.doubleValue
        } else {
            opacity = GhosttyApp.shared.defaultBackgroundOpacity
        }

        return baseColor.withAlphaComponent(clampedGhosttyBackgroundOpacity(opacity))
    }

    private static func resolvedBrowserChromeBackgroundColor(
        from notification: Notification? = nil,
        appAppearance: NSAppearance? = NSApp?.effectiveAppearance
    ) -> NSColor {
        if isDarkAppearance(appAppearance: appAppearance) {
            return resolvedGhosttyBackgroundColor(from: notification)
        }
        return NSColor.windowBackgroundColor
    }

    let id: UUID
    let panelType: PanelType = .browser

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    /// The underlying web view
    let webView: WKWebView

    /// Prevent the omnibar from auto-focusing for a short window after explicit programmatic focus.
    /// This avoids races where SwiftUI focus state steals first responder back from WebKit.
    private var suppressOmnibarAutofocusUntil: Date?

    /// Prevent forcing web-view focus when another UI path requested omnibar focus.
    /// Used to keep omnibar text-field focus from being immediately stolen by panel focus.
    private var suppressWebViewFocusUntil: Date?
    private var suppressWebViewFocusForAddressBar: Bool = false
    private let blankURLString = "about:blank"

    /// Published URL being displayed
    @Published private(set) var currentURL: URL?

    /// Whether the browser panel should render its WKWebView in the content area.
    /// New browser tabs stay in an empty "new tab" state until first navigation.
    @Published private(set) var shouldRenderWebView: Bool = false

    /// Published page title
    @Published private(set) var pageTitle: String = ""

    /// Published favicon (PNG data). When present, the tab bar can render it instead of a SF symbol.
    @Published private(set) var faviconPNGData: Data?

    /// Published loading state
    @Published private(set) var isLoading: Bool = false

    /// Published download state for browser downloads (navigation + context menu).
    @Published private(set) var isDownloading: Bool = false

    /// Published can go back state
    @Published private(set) var canGoBack: Bool = false

    /// Published can go forward state
    @Published private(set) var canGoForward: Bool = false

    /// Published estimated progress (0.0 - 1.0)
    @Published private(set) var estimatedProgress: Double = 0.0

    /// Increment to request a UI-only flash highlight (e.g. from a keyboard shortcut).
    @Published private(set) var focusFlashToken: Int = 0

    /// Sticky omnibar-focus intent. This survives view mount timing races and is
    /// cleared only after BrowserPanelView acknowledges handling it.
    @Published private(set) var pendingAddressBarFocusRequestId: UUID?

    private var cancellables = Set<AnyCancellable>()
    private var navigationDelegate: BrowserNavigationDelegate?
    private var uiDelegate: BrowserUIDelegate?
    private var downloadDelegate: BrowserDownloadDelegate?
    private var webViewObservers: [NSKeyValueObservation] = []
    private var activeDownloadCount: Int = 0

    // Avoid flickering the loading indicator for very fast navigations.
    private let minLoadingIndicatorDuration: TimeInterval = 0.35
    private var loadingStartedAt: Date?
    private var loadingEndWorkItem: DispatchWorkItem?
    private var loadingGeneration: Int = 0

    private var faviconTask: Task<Void, Never>?
    private var faviconRefreshGeneration: Int = 0
    private var lastFaviconURLString: String?
    private let minPageZoom: CGFloat = 0.25
    private let maxPageZoom: CGFloat = 5.0
    private let pageZoomStep: CGFloat = 0.1
    private var insecureHTTPBypassHostOnce: String?
    // Persist user intent across WebKit detach/reattach churn (split/layout updates).
    private var preferredDeveloperToolsVisible: Bool = false
    private var forceDeveloperToolsRefreshOnNextAttach: Bool = false
    private var developerToolsRestoreRetryWorkItem: DispatchWorkItem?
    private var developerToolsRestoreRetryAttempt: Int = 0
    private let developerToolsRestoreRetryDelay: TimeInterval = 0.05
    private let developerToolsRestoreRetryMaxAttempts: Int = 40
    private var forcedDarkModeEnabled: Bool
    private var forcedDarkModeOpacity: Double

    var displayTitle: String {
        if !pageTitle.isEmpty {
            return pageTitle
        }
        if let url = currentURL {
            return url.host ?? url.absoluteString
        }
        return "New tab"
    }

    var displayIcon: String? {
        "globe"
    }

    var isDirty: Bool {
        false
    }

    init(workspaceId: UUID, initialURL: URL? = nil, bypassInsecureHTTPHostOnce: String? = nil) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.insecureHTTPBypassHostOnce = BrowserInsecureHTTPSettings.normalizeHost(bypassInsecureHTTPHostOnce ?? "")
        self.forcedDarkModeEnabled = BrowserForcedDarkModeSettings.enabled()
        self.forcedDarkModeOpacity = BrowserForcedDarkModeSettings.opacity()

        // Configure web view
        let config = WKWebViewConfiguration()
        config.processPool = BrowserPanel.sharedProcessPool
        // Ensure browser cookies/storage persist across navigations and launches.
        // This reduces repeated consent/bot-challenge flows on sites like Google.
        config.websiteDataStore = .default()

        // Enable developer extras (DevTools)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Enable JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Set up web view
        let webView = CmuxWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // Required for Web Inspector support on recent WebKit SDKs.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        // Match the empty-page background to the terminal theme so newly-created browsers
        // don't flash white before content loads.
        webView.underPageBackgroundColor = Self.resolvedBrowserChromeBackgroundColor()

        // Always present as Safari.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent

        self.webView = webView

        // Set up navigation delegate
        let navDelegate = BrowserNavigationDelegate()
        navDelegate.didFinish = { webView in
            BrowserHistoryStore.shared.recordVisit(url: webView.url, title: webView.title)
            Task { @MainActor [weak self] in
                self?.refreshFavicon(from: webView)
                self?.applyForcedDarkModeIfNeeded()
            }
        }
        navDelegate.didFailNavigation = { [weak self] _, failedURL in
            Task { @MainActor in
                guard let self else { return }
                // Clear stale title/favicon from the previous page so the tab
                // shows the failed URL instead of the old page's branding.
                self.pageTitle = failedURL.isEmpty ? "" : failedURL
                self.faviconPNGData = nil
                self.lastFaviconURLString = nil
            }
        }
        navDelegate.openInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        navDelegate.shouldBlockInsecureHTTPNavigation = { [weak self] url in
            self?.shouldBlockInsecureHTTPNavigation(to: url) ?? false
        }
        navDelegate.handleBlockedInsecureHTTPNavigation = { [weak self] request, intent in
            self?.presentInsecureHTTPAlert(for: request, intent: intent, recordTypedNavigation: false)
        }
        // Set up download delegate for navigation-based downloads.
        // Downloads save to a temp file synchronously (no NSSavePanel during WebKit
        // callbacks), then show NSSavePanel after the download completes.
        let dlDelegate = BrowserDownloadDelegate()
        dlDelegate.onDownloadStarted = { [weak self] _ in
            self?.beginDownloadActivity()
        }
        dlDelegate.onDownloadReadyToSave = { [weak self] in
            self?.endDownloadActivity()
        }
        dlDelegate.onDownloadFailed = { [weak self] _ in
            self?.endDownloadActivity()
        }
        navDelegate.downloadDelegate = dlDelegate
        self.downloadDelegate = dlDelegate
        webView.onContextMenuDownloadStateChanged = { [weak self] downloading in
            if downloading {
                self?.beginDownloadActivity()
            } else {
                self?.endDownloadActivity()
            }
        }
        webView.navigationDelegate = navDelegate
        self.navigationDelegate = navDelegate

        // Set up UI delegate (handles cmd+click, target=_blank, and context menu)
        let browserUIDelegate = BrowserUIDelegate()
        browserUIDelegate.openInNewTab = { [weak self] url in
            guard let self else { return }
            self.openLinkInNewTab(url: url)
        }
        browserUIDelegate.requestNavigation = { [weak self] request, intent in
            self?.requestNavigation(request, intent: intent)
        }
        webView.uiDelegate = browserUIDelegate
        self.uiDelegate = browserUIDelegate

        // Observe web view properties
        setupObservers()
        applyForcedDarkModeIfNeeded()

        // Navigate to initial URL if provided
        if let url = initialURL {
            shouldRenderWebView = true
            navigate(to: url)
        }
    }

    private func beginDownloadActivity() {
        let apply = {
            self.activeDownloadCount += 1
            self.isDownloading = self.activeDownloadCount > 0
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func endDownloadActivity() {
        let apply = {
            self.activeDownloadCount = max(0, self.activeDownloadCount - 1)
            self.isDownloading = self.activeDownloadCount > 0
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func triggerFlash() {
        focusFlashToken &+= 1
    }

    private func setupObservers() {
        // URL changes
        let urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.currentURL = webView.url
            }
        }
        webViewObservers.append(urlObserver)

        // Title changes
        let titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                // Keep showing the last non-empty title while the new navigation is loading.
                // WebKit often clears title to nil/"" during reload/navigation, which causes
                // a distracting tab-title flash (e.g. to host/URL). Only accept non-empty titles.
                let trimmed = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self?.pageTitle = trimmed
            }
        }
        webViewObservers.append(titleObserver)

        // Loading state
        let loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.handleWebViewLoadingChanged(webView.isLoading)
            }
        }
        webViewObservers.append(loadingObserver)

        // Can go back
        let backObserver = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoBack = webView.canGoBack
            }
        }
        webViewObservers.append(backObserver)

        // Can go forward
        let forwardObserver = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoForward = webView.canGoForward
            }
        }
        webViewObservers.append(forwardObserver)

        // Progress
        let progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.estimatedProgress = webView.estimatedProgress
            }
        }
        webViewObservers.append(progressObserver)

        NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)
            .sink { [weak self] notification in
                guard let self else { return }
                self.webView.underPageBackgroundColor = Self.resolvedBrowserChromeBackgroundColor(from: notification)
            }
            .store(in: &cancellables)
    }

    // MARK: - Panel Protocol

    func focus() {
        if shouldSuppressWebViewFocus() {
            return
        }

        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }

        // If nothing meaningful is loaded yet, prefer letting the omnibar take focus.
        if !webView.isLoading {
            let urlString = webView.url?.absoluteString ?? currentURL?.absoluteString
            if urlString == nil || urlString == "about:blank" {
                return
            }
        }

        if Self.responderChainContains(window.firstResponder, target: webView) {
            return
        }
        window.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let window = webView.window else { return }
        if Self.responderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        // Ensure we don't keep a hidden WKWebView (or its content view) as first responder while
        // bonsplit/SwiftUI reshuffles views during close.
        unfocus()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        navigationDelegate = nil
        uiDelegate = nil
        webViewObservers.removeAll()
        cancellables.removeAll()
        faviconTask?.cancel()
        faviconTask = nil
    }

    private func refreshFavicon(from webView: WKWebView) {
        faviconTask?.cancel()
        faviconTask = nil

        guard let pageURL = webView.url else { return }
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        faviconRefreshGeneration &+= 1
        let refreshGeneration = faviconRefreshGeneration

        faviconTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            // Try to discover the best icon URL from the document.
            let js = """
            (() => {
              const links = Array.from(document.querySelectorAll(
                'link[rel~=\"icon\"], link[rel=\"shortcut icon\"], link[rel=\"apple-touch-icon\"], link[rel=\"apple-touch-icon-precomposed\"]'
              ));
              function score(link) {
                const v = (link.sizes && link.sizes.value) ? link.sizes.value : '';
                if (v === 'any') return 1000;
                let max = 0;
                for (const part of v.split(/\\s+/)) {
                  const m = part.match(/(\\d+)x(\\d+)/);
                  if (!m) continue;
                  const a = parseInt(m[1], 10);
                  const b = parseInt(m[2], 10);
                  if (Number.isFinite(a)) max = Math.max(max, a);
                  if (Number.isFinite(b)) max = Math.max(max, b);
                }
                return max;
              }
              links.sort((a, b) => score(b) - score(a));
              return links[0]?.href || '';
            })();
            """

            var discoveredURL: URL?
            if let href = try? await webView.evaluateJavaScript(js) as? String {
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let u = URL(string: trimmed) {
                    discoveredURL = u
                }
            }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            let fallbackURL = URL(string: "/favicon.ico", relativeTo: pageURL)
            let iconURL = discoveredURL ?? fallbackURL
            guard let iconURL else { return }

            // Avoid repeated fetches.
            let iconURLString = iconURL.absoluteString
            if iconURLString == lastFaviconURLString, faviconPNGData != nil {
                return
            }
            lastFaviconURLString = iconURLString

            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 2.0
            req.cachePolicy = .returnCacheDataElseLoad
            req.setValue(BrowserUserAgentSettings.safariUserAgent, forHTTPHeaderField: "User-Agent")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                return
            }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }

            // Use >= 2x the rendered point size so we don't upscale (blurry) on Retina.
            guard let png = Self.makeFaviconPNGData(from: data, targetPx: 32) else { return }
            // Only update if we got a real icon; keep the old one otherwise to avoid flashes.
            faviconPNGData = png
        }
    }

    private func isCurrentFaviconRefresh(generation: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        return generation == faviconRefreshGeneration
    }

    @MainActor
    private static func makeFaviconPNGData(from raw: Data, targetPx: Int) -> Data? {
        guard let image = NSImage(data: raw) else { return nil }

        let px = max(16, min(128, targetPx))
        let size = NSSize(width: px, height: px)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        ctx?.shouldAntialias = true
        NSGraphicsContext.current = ctx

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Aspect-fit into the target square.
        let srcSize = image.size
        let scale = min(size.width / max(1, srcSize.width), size.height / max(1, srcSize.height))
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let drawOrigin = NSPoint(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0)
        // Align to integral pixels to avoid soft edges at small sizes.
        let drawRect = NSRect(
            x: round(drawOrigin.x),
            y: round(drawOrigin.y),
            width: round(drawSize.width),
            height: round(drawSize.height)
        )

        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: srcSize),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        return rep.representation(using: .png, properties: [:])
    }

    private func handleWebViewLoadingChanged(_ newValue: Bool) {
        if newValue {
            // Any new load invalidates older favicon fetches, even for same-URL reloads.
            faviconRefreshGeneration &+= 1
            faviconTask?.cancel()
            faviconTask = nil
            lastFaviconURLString = nil
            loadingGeneration &+= 1
            loadingEndWorkItem?.cancel()
            loadingEndWorkItem = nil
            loadingStartedAt = Date()
            isLoading = true
            return
        }

        let genAtEnd = loadingGeneration
        let startedAt = loadingStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, minLoadingIndicatorDuration - elapsed)

        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil

        if remaining <= 0.0001 {
            isLoading = false
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If loading restarted, ignore this end.
            guard self.loadingGeneration == genAtEnd else { return }
            // If WebKit is still loading, ignore.
            guard !self.webView.isLoading else { return }
            self.isLoading = false
        }
        loadingEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    // MARK: - Navigation

    /// Navigate to a URL
    func navigate(to url: URL, recordTypedNavigation: Bool = false) {
        let request = URLRequest(url: url)
        if shouldBlockInsecureHTTPNavigation(to: url) {
            presentInsecureHTTPAlert(for: request, intent: .currentTab, recordTypedNavigation: recordTypedNavigation)
            return
        }
        navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: recordTypedNavigation)
    }

    private func navigateWithoutInsecureHTTPPrompt(to url: URL, recordTypedNavigation: Bool) {
        let request = URLRequest(url: url)
        navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: recordTypedNavigation)
    }

    private func navigateWithoutInsecureHTTPPrompt(request: URLRequest, recordTypedNavigation: Bool) {
        guard let url = request.url else { return }
        // Some installs can end up with a legacy Chrome UA override; keep this pinned.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        shouldRenderWebView = true
        if recordTypedNavigation {
            BrowserHistoryStore.shared.recordTypedNavigation(url: url)
        }
        navigationDelegate?.lastAttemptedURL = url
        webView.load(browserPreparedNavigationRequest(request))
    }

    /// Navigate with smart URL/search detection
    /// - If input looks like a URL, navigate to it
    /// - Otherwise, perform a web search
    func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = resolveNavigableURL(from: trimmed) {
            navigate(to: url, recordTypedNavigation: true)
            return
        }

        let engine = BrowserSearchSettings.currentSearchEngine()
        guard let searchURL = engine.searchURL(query: trimmed) else { return }
        navigate(to: searchURL)
    }

    func resolveNavigableURL(from input: String) -> URL? {
        resolveBrowserNavigableURL(input)
    }

    private func shouldBlockInsecureHTTPNavigation(to url: URL) -> Bool {
        if browserShouldConsumeOneTimeInsecureHTTPBypass(url, bypassHostOnce: &insecureHTTPBypassHostOnce) {
            return false
        }
        return browserShouldBlockInsecureHTTPURL(url)
    }

    private func requestNavigation(_ request: URLRequest, intent: BrowserInsecureHTTPNavigationIntent) {
        guard let url = request.url else { return }
        if shouldBlockInsecureHTTPNavigation(to: url) {
            presentInsecureHTTPAlert(for: request, intent: intent, recordTypedNavigation: false)
            return
        }
        switch intent {
        case .currentTab:
            navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: false)
        case .newTab:
            openLinkInNewTab(url: url)
        }
    }

    private func presentInsecureHTTPAlert(
        for request: URLRequest,
        intent: BrowserInsecureHTTPNavigationIntent,
        recordTypedNavigation: Bool
    ) {
        guard let url = request.url else { return }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Connection isn't secure"
        alert.informativeText = """
        \(host) uses plain HTTP, so traffic can be read or modified on the network.

        Open this URL in your default browser, or proceed in cmux.
        """
        alert.addButton(withTitle: "Open in Default Browser")
        alert.addButton(withTitle: "Proceed in cmux")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always allow this host in cmux"

        let response = alert.runModal()
        if browserShouldPersistInsecureHTTPAllowlistSelection(
            response: response,
            suppressionEnabled: alert.suppressionButton?.state == .on
        ) {
            BrowserInsecureHTTPSettings.addAllowedHost(host)
        }
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn:
            switch intent {
            case .currentTab:
                insecureHTTPBypassHostOnce = host
                navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: recordTypedNavigation)
            case .newTab:
                openLinkInNewTab(url: url, bypassInsecureHTTPHostOnce: host)
            }
        default:
            return
        }
    }

    deinit {
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        let webView = webView
        Task { @MainActor in
            BrowserWindowPortalRegistry.detach(webView: webView)
        }
        webViewObservers.removeAll()
        cancellables.removeAll()
    }
}

func resolveBrowserNavigableURL(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.contains(" ") else { return nil }

    // Check localhost/loopback before generic URL parsing because
    // URL(string: "localhost:3777") treats "localhost" as a scheme.
    let lower = trimmed.lowercased()
    if lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]") {
        return URL(string: "http://\(trimmed)")
    }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            return url
        }
        return nil
    }

    if trimmed.contains(":") || trimmed.contains("/") {
        return URL(string: "https://\(trimmed)")
    }

    if trimmed.contains(".") {
        return URL(string: "https://\(trimmed)")
    }

    return nil
}

extension BrowserPanel {

    /// Go back in history
    func goBack() {
        guard canGoBack else { return }
        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        webView.goForward()
    }

    /// Open a link in a new browser surface in the same pane
    func openLinkInNewTab(url: URL, bypassInsecureHTTPHostOnce: String? = nil) {
        guard let tabManager = AppDelegate.shared?.tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              let paneId = workspace.paneId(forPanelId: id) else { return }
        workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
    }

    /// Reload the current page
    func reload() {
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        webView.reload()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
    }

    @discardableResult
    func toggleDeveloperTools() -> Bool {
#if DEBUG
        dlog(
            "browser.devtools toggle.begin panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        guard let inspector = webView.cmuxInspectorObject() else { return false }
        let isVisibleSelector = NSSelectorFromString("isVisible")
        let visible = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        let targetVisible = !visible
        let selector = NSSelectorFromString(targetVisible ? "show" : "close")
        guard inspector.responds(to: selector) else { return false }
        inspector.cmuxCallVoid(selector: selector)
        preferredDeveloperToolsVisible = targetVisible
        if targetVisible {
            let visibleAfterToggle = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
            if visibleAfterToggle {
                cancelDeveloperToolsRestoreRetry()
            } else {
                developerToolsRestoreRetryAttempt = 0
                scheduleDeveloperToolsRestoreRetry()
            }
        } else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
        }
#if DEBUG
        dlog(
            "browser.devtools toggle.end panel=\(id.uuidString.prefix(5)) targetVisible=\(targetVisible ? 1 : 0) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            dlog(
                "browser.devtools toggle.tick panel=\(self.id.uuidString.prefix(5)) " +
                "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
            )
        }
#endif
        return true
    }

    @discardableResult
    func showDeveloperTools() -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }
        let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if !visible {
            let showSelector = NSSelectorFromString("show")
            guard inspector.responds(to: showSelector) else { return false }
            inspector.cmuxCallVoid(selector: showSelector)
        }
        preferredDeveloperToolsVisible = true
        if (inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false) {
            cancelDeveloperToolsRestoreRetry()
        } else {
            scheduleDeveloperToolsRestoreRetry()
        }
        return true
    }

    @discardableResult
    func showDeveloperToolsConsole() -> Bool {
        guard showDeveloperTools() else { return false }
        guard let inspector = webView.cmuxInspectorObject() else { return true }
        // WebKit private inspector API differs by OS; try known console selectors.
        let consoleSelectors = [
            "showConsole",
            "showConsoleTab",
            "showConsoleView",
        ]
        for raw in consoleSelectors {
            let selector = NSSelectorFromString(raw)
            if inspector.responds(to: selector) {
                inspector.cmuxCallVoid(selector: selector)
                break
            }
        }
        return true
    }

    /// Called before WKWebView detaches so manual inspector closes are respected.
    func syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: Bool = false) {
        guard let inspector = webView.cmuxInspectorObject() else { return }
        guard let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) else { return }
        if visible {
            preferredDeveloperToolsVisible = true
            cancelDeveloperToolsRestoreRetry()
            return
        }
        if preserveVisibleIntent && preferredDeveloperToolsVisible {
            return
        }
        preferredDeveloperToolsVisible = false
        cancelDeveloperToolsRestoreRetry()
    }

    /// Called after WKWebView reattaches to keep inspector stable across split/layout churn.
    func restoreDeveloperToolsAfterAttachIfNeeded() {
        guard preferredDeveloperToolsVisible else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
            return
        }
        guard let inspector = webView.cmuxInspectorObject() else {
            scheduleDeveloperToolsRestoreRetry()
            return
        }

        let shouldForceRefresh = forceDeveloperToolsRefreshOnNextAttach
        forceDeveloperToolsRefreshOnNextAttach = false

        let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visible {
            #if DEBUG
            if shouldForceRefresh {
                dlog("browser.devtools refresh.consumeVisible panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
            }
            #endif
            cancelDeveloperToolsRestoreRetry()
            return
        }

        let selector = NSSelectorFromString("show")
        guard inspector.responds(to: selector) else {
            cancelDeveloperToolsRestoreRetry()
            return
        }
        #if DEBUG
        if shouldForceRefresh {
            dlog("browser.devtools refresh.forceShowWhenHidden panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
        }
        #endif
        inspector.cmuxCallVoid(selector: selector)
        preferredDeveloperToolsVisible = true
        let visibleAfterShow = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visibleAfterShow {
            cancelDeveloperToolsRestoreRetry()
        } else {
            scheduleDeveloperToolsRestoreRetry()
        }
    }

    @discardableResult
    func isDeveloperToolsVisible() -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }
        return inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
    }

    @discardableResult
    func hideDeveloperTools() -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }
        let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visible {
            let selector = NSSelectorFromString("close")
            guard inspector.responds(to: selector) else { return false }
            inspector.cmuxCallVoid(selector: selector)
        }
        preferredDeveloperToolsVisible = false
        forceDeveloperToolsRefreshOnNextAttach = false
        cancelDeveloperToolsRestoreRetry()
        return true
    }

    /// During split/layout transitions SwiftUI can briefly mark the browser surface hidden
    /// while its container is off-window. Avoid detaching in that transient phase if
    /// DevTools is intended to remain open, because detach/reattach can blank inspector content.
    func shouldPreserveWebViewAttachmentDuringTransientHide() -> Bool {
        preferredDeveloperToolsVisible
    }

    func requestDeveloperToolsRefreshAfterNextAttach(reason: String) {
        guard preferredDeveloperToolsVisible else { return }
        forceDeveloperToolsRefreshOnNextAttach = true
        #if DEBUG
        dlog("browser.devtools refresh.request panel=\(id.uuidString.prefix(5)) reason=\(reason) \(debugDeveloperToolsStateSummary())")
        #endif
    }

    func hasPendingDeveloperToolsRefreshAfterAttach() -> Bool {
        forceDeveloperToolsRefreshOnNextAttach
    }

    @discardableResult
    func zoomIn() -> Bool {
        applyPageZoom(webView.pageZoom + pageZoomStep)
    }

    @discardableResult
    func zoomOut() -> Bool {
        applyPageZoom(webView.pageZoom - pageZoomStep)
    }

    @discardableResult
    func resetZoom() -> Bool {
        applyPageZoom(1.0)
    }

    /// Take a snapshot of the web view
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let error = error {
                NSLog("BrowserPanel snapshot error: %@", error.localizedDescription)
                completion(nil)
                return
            }
            completion(image)
        }
    }

    /// Execute JavaScript
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func setForcedDarkMode(enabled: Bool, opacity: Double) {
        forcedDarkModeEnabled = enabled
        forcedDarkModeOpacity = BrowserForcedDarkModeSettings.normalizedOpacity(opacity)
        applyForcedDarkModeIfNeeded()
    }

    func refreshAppearanceDrivenColors() {
        webView.underPageBackgroundColor = Self.resolvedBrowserChromeBackgroundColor()
    }

    func suppressOmnibarAutofocus(for seconds: TimeInterval) {
        suppressOmnibarAutofocusUntil = Date().addingTimeInterval(seconds)
    }

    func suppressWebViewFocus(for seconds: TimeInterval) {
        suppressWebViewFocusUntil = Date().addingTimeInterval(seconds)
    }

    func clearWebViewFocusSuppression() {
        suppressWebViewFocusUntil = nil
    }

    func shouldSuppressOmnibarAutofocus() -> Bool {
        if let until = suppressOmnibarAutofocusUntil {
            return Date() < until
        }
        return false
    }

    func shouldSuppressWebViewFocus() -> Bool {
        if suppressWebViewFocusForAddressBar {
            return true
        }
        if let until = suppressWebViewFocusUntil {
            return Date() < until
        }
        return false
    }

    func beginSuppressWebViewFocusForAddressBar() {
        suppressWebViewFocusForAddressBar = true
    }

    func endSuppressWebViewFocusForAddressBar() {
        suppressWebViewFocusForAddressBar = false
    }

    @discardableResult
    func requestAddressBarFocus() -> UUID {
        beginSuppressWebViewFocusForAddressBar()
        if let pendingAddressBarFocusRequestId {
            return pendingAddressBarFocusRequestId
        }
        let requestId = UUID()
        pendingAddressBarFocusRequestId = requestId
        return requestId
    }

    func acknowledgeAddressBarFocusRequest(_ requestId: UUID) {
        guard pendingAddressBarFocusRequestId == requestId else { return }
        pendingAddressBarFocusRequestId = nil
    }

    /// Returns the most reliable URL string for omnibar-related matching and UI decisions.
    /// `currentURL` can lag behind navigation changes, so prefer the live WKWebView URL.
    func preferredURLStringForOmnibar() -> String? {
        if let webViewURL = webView.url?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !webViewURL.isEmpty,
           webViewURL != blankURLString {
            return webViewURL
        }

        if let current = currentURL?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty,
           current != blankURLString {
            return current
        }

        return nil
    }

}

private extension BrowserPanel {
    func applyForcedDarkModeIfNeeded() {
        let script = makeForcedDarkModeScript(
            enabled: forcedDarkModeEnabled,
            opacityPercent: forcedDarkModeOpacity
        )
        webView.evaluateJavaScript(script) { _, error in
            #if DEBUG
            if let error {
                dlog("browser.forcedDarkMode error=\(error.localizedDescription)")
            }
            #endif
        }
    }

    func makeForcedDarkModeScript(enabled: Bool, opacityPercent: Double) -> String {
        let clampedOpacity = BrowserForcedDarkModeSettings.normalizedOpacity(opacityPercent) / 100.0
        let opacityLiteral = String(format: "%.4f", clampedOpacity)
        let enabledLiteral = enabled ? "true" : "false"
        return """
        (() => {
          const overlayId = 'cmux-forced-dark-mode-overlay';
          const shouldEnable = \(enabledLiteral);
          const overlayOpacity = \(opacityLiteral);
          const root = document.documentElement || document.body;
          if (!root) return;

          let overlay = document.getElementById(overlayId);
          if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = overlayId;
            overlay.style.position = 'fixed';
            overlay.style.top = '0';
            overlay.style.left = '0';
            overlay.style.right = '0';
            overlay.style.bottom = '0';
            overlay.style.backgroundColor = 'black';
            overlay.style.pointerEvents = 'none';
            overlay.style.zIndex = '2147483647';
            overlay.style.transition = 'opacity 120ms ease';
            overlay.style.opacity = '0';
            root.appendChild(overlay);
          }

          overlay.style.display = shouldEnable ? 'block' : 'none';
          overlay.style.opacity = shouldEnable ? String(overlayOpacity) : '0';
        })();
        """
    }

    func scheduleDeveloperToolsRestoreRetry() {
        guard preferredDeveloperToolsVisible else { return }
        guard developerToolsRestoreRetryWorkItem == nil else { return }
        guard developerToolsRestoreRetryAttempt < developerToolsRestoreRetryMaxAttempts else { return }

        developerToolsRestoreRetryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.developerToolsRestoreRetryWorkItem = nil
            self.restoreDeveloperToolsAfterAttachIfNeeded()
        }
        developerToolsRestoreRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + developerToolsRestoreRetryDelay, execute: work)
    }

    func cancelDeveloperToolsRestoreRetry() {
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        developerToolsRestoreRetryAttempt = 0
    }
}

#if DEBUG
extension BrowserPanel {
    private static func debugRectDescription(_ rect: NSRect) -> String {
        String(
            format: "%.1f,%.1f %.1fx%.1f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private static func debugObjectToken(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private static func debugInspectorSubviewCount(in root: NSView) -> Int {
        var stack: [NSView] = [root]
        var count = 0
        while let current = stack.popLast() {
            for subview in current.subviews {
                if String(describing: type(of: subview)).contains("WKInspector") {
                    count += 1
                }
                stack.append(subview)
            }
        }
        return count
    }

    func debugDeveloperToolsStateSummary() -> String {
        let preferred = preferredDeveloperToolsVisible ? 1 : 0
        let visible = isDeveloperToolsVisible() ? 1 : 0
        let inspector = webView.cmuxInspectorObject() == nil ? 0 : 1
        let attached = webView.superview == nil ? 0 : 1
        let inWindow = webView.window == nil ? 0 : 1
        let forceRefresh = forceDeveloperToolsRefreshOnNextAttach ? 1 : 0
        return "pref=\(preferred) vis=\(visible) inspector=\(inspector) attached=\(attached) inWindow=\(inWindow) restoreRetry=\(developerToolsRestoreRetryAttempt) forceRefresh=\(forceRefresh)"
    }

    func debugDeveloperToolsGeometrySummary() -> String {
        let container = webView.superview
        let containerBounds = container?.bounds ?? .zero
        let webFrame = webView.frame
        let inspectorInsets = max(0, containerBounds.height - webFrame.height)
        let inspectorOverflow = max(0, webFrame.maxY - containerBounds.maxY)
        let inspectorHeightApprox = max(inspectorInsets, inspectorOverflow)
        let inspectorSubviews = container.map { Self.debugInspectorSubviewCount(in: $0) } ?? 0
        let containerType = container.map { String(describing: type(of: $0)) } ?? "nil"
        return "webFrame=\(Self.debugRectDescription(webFrame)) webBounds=\(Self.debugRectDescription(webView.bounds)) webWin=\(webView.window?.windowNumber ?? -1) super=\(Self.debugObjectToken(container)) superType=\(containerType) superBounds=\(Self.debugRectDescription(containerBounds)) inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) inspectorInsets=\(String(format: "%.1f", inspectorInsets)) inspectorOverflow=\(String(format: "%.1f", inspectorOverflow)) inspectorSubviews=\(inspectorSubviews)"
    }
}
#endif

private extension BrowserPanel {
    @discardableResult
    func applyPageZoom(_ candidate: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, candidate))
        if abs(webView.pageZoom - clamped) < 0.0001 {
            return false
        }
        webView.pageZoom = clamped
        return true
    }

    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }
}

private extension WKWebView {
    func cmuxInspectorObject() -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector),
              let inspector = perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        return inspector
    }
}

private extension NSObject {
    func cmuxCallBool(selector: Selector) -> Bool? {
        guard responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        return fn(self, selector)
    }

    func cmuxCallVoid(selector: Selector) {
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}

// MARK: - Download Delegate

/// Handles WKDownload lifecycle by saving to a temp file synchronously (no UI
/// during WebKit callbacks), then showing NSSavePanel after the download finishes.
private class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private struct DownloadState {
        let tempURL: URL
        let suggestedFilename: String
    }

    /// Tracks active downloads keyed by WKDownload identity.
    private var activeDownloads: [ObjectIdentifier: DownloadState] = [:]
    private let activeDownloadsLock = NSLock()
    var onDownloadStarted: ((String) -> Void)?
    var onDownloadReadyToSave: (() -> Void)?
    var onDownloadFailed: ((Error) -> Void)?

    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func sanitizedFilename(_ raw: String, fallbackURL: URL?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (trimmed as NSString).lastPathComponent
        let fromURL = fallbackURL?.lastPathComponent ?? ""
        let base = candidate.isEmpty ? fromURL : candidate
        let replaced = base.replacingOccurrences(of: ":", with: "-")
        let safe = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "download" : safe
    }

    private func storeState(_ state: DownloadState, for download: WKDownload) {
        activeDownloadsLock.lock()
        activeDownloads[ObjectIdentifier(download)] = state
        activeDownloadsLock.unlock()
    }

    private func removeState(for download: WKDownload) -> DownloadState? {
        activeDownloadsLock.lock()
        let state = activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
        return state
    }

    private func notifyOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Save to a temp file — return synchronously so WebKit is never blocked.
        let safeFilename = Self.sanitizedFilename(suggestedFilename, fallbackURL: response.url)
        let tempFilename = "\(UUID().uuidString)-\(safeFilename)"
        let destURL = Self.tempDir.appendingPathComponent(tempFilename, isDirectory: false)
        try? FileManager.default.removeItem(at: destURL)
        storeState(DownloadState(tempURL: destURL, suggestedFilename: safeFilename), for: download)
        notifyOnMain { [weak self] in
            self?.onDownloadStarted?(safeFilename)
        }
        #if DEBUG
        dlog("download.decideDestination file=\(safeFilename)")
        #endif
        NSLog("BrowserPanel download: temp path=%@", destURL.path)
        completionHandler(destURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = removeState(for: download) else {
            #if DEBUG
            dlog("download.finished missing-state")
            #endif
            return
        }
        #if DEBUG
        dlog("download.finished file=\(info.suggestedFilename)")
        #endif
        NSLog("BrowserPanel download finished: %@", info.suggestedFilename)

        // Show NSSavePanel on the next runloop iteration (safe context).
        DispatchQueue.main.async {
            self.onDownloadReadyToSave?()
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = info.suggestedFilename
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

            savePanel.begin { result in
                guard result == .OK, let destURL = savePanel.url else {
                    try? FileManager.default.removeItem(at: info.tempURL)
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: info.tempURL, to: destURL)
                    NSLog("BrowserPanel download saved: %@", destURL.path)
                } catch {
                    NSLog("BrowserPanel download move failed: %@", error.localizedDescription)
                    try? FileManager.default.removeItem(at: info.tempURL)
                }
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let info = removeState(for: download) {
            try? FileManager.default.removeItem(at: info.tempURL)
        }
        notifyOnMain { [weak self] in
            self?.onDownloadFailed?(error)
        }
        #if DEBUG
        dlog("download.failed error=\(error.localizedDescription)")
        #endif
        NSLog("BrowserPanel download failed: %@", error.localizedDescription)
    }
}

// MARK: - Navigation Delegate

private class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    var didFinish: ((WKWebView) -> Void)?
    var didFailNavigation: ((WKWebView, String) -> Void)?
    var openInNewTab: ((URL) -> Void)?
    var shouldBlockInsecureHTTPNavigation: ((URL) -> Bool)?
    var handleBlockedInsecureHTTPNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    /// Direct reference to the download delegate — must be set synchronously in didBecome callbacks.
    var downloadDelegate: WKDownloadDelegate?
    /// The URL of the last navigation that was attempted. Used to preserve the omnibar URL
    /// when a provisional navigation fails (e.g. connection refused on localhost:3000).
    var lastAttemptedURL: URL?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastAttemptedURL = webView.url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("BrowserPanel navigation failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        NSLog("BrowserPanel provisional navigation failed: %@", error.localizedDescription)

        // Cancelled navigations (e.g. rapid typing) are not real errors.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }

        // "Frame load interrupted" (WebKitErrorDomain code 102) fires when a
        // navigation response is converted into a download via .download policy.
        // This is expected and should not show an error page.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return
        }

        let failedURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? lastAttemptedURL?.absoluteString
            ?? ""
        didFailNavigation?(webView, failedURL)
        loadErrorPage(in: webView, failedURL: failedURL, error: nsError)
    }

    func webView(_ webView: WKWebView, webContentProcessDidTerminate: WKWebView) {
        NSLog("BrowserPanel web content process terminated, reloading")
        webView.reload()
    }

    private func loadErrorPage(in webView: WKWebView, failedURL: String, error: NSError) {
        let title: String
        let message: String

        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorTimedOut):
            title = "Can\u{2019}t reach this page"
            message = "\(failedURL.isEmpty ? "The site" : failedURL) refused to connect. Check that a server is running on this address."
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            title = "No internet connection"
            message = "Check your network connection and try again."
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            title = "Connection isn\u{2019}t secure"
            message = "The certificate for this site is invalid."
        default:
            title = "Can\u{2019}t open this page"
            message = error.localizedDescription
        }

        let escapedURL = failedURL
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex; align-items: center; justify-content: center;
            min-height: 80vh; margin: 0; padding: 20px;
            background: #1a1a1a; color: #e0e0e0;
        }
        .container { text-align: center; max-width: 420px; }
        h1 { font-size: 18px; font-weight: 600; margin-bottom: 8px; }
        p { font-size: 13px; color: #999; line-height: 1.5; }
        .url { font-size: 12px; color: #666; word-break: break-all; margin-top: 16px; }
        button {
            margin-top: 20px; padding: 6px 20px;
            background: #333; color: #e0e0e0; border: 1px solid #555;
            border-radius: 6px; font-size: 13px; cursor: pointer;
        }
        button:hover { background: #444; }
        @media (prefers-color-scheme: light) {
            body { background: #fafafa; color: #222; }
            p { color: #666; }
            .url { color: #999; }
            button { background: #eee; color: #222; border-color: #ccc; }
            button:hover { background: #ddd; }
        }
        </style>
        </head>
        <body>
        <div class="container">
            <h1>\(title)</h1>
            <p>\(message)</p>
            <div class="url">\(escapedURL)</div>
            <button onclick="location.reload()">Reload</button>
        </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failedURL))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false,
           shouldBlockInsecureHTTPNavigation?(url) == true {
            let intent: BrowserInsecureHTTPNavigationIntent
            if navigationAction.navigationType == .linkActivated,
               navigationAction.modifierFlags.contains(.command) {
                intent = .newTab
            } else {
                intent = .currentTab
            }
            handleBlockedInsecureHTTPNavigation?(navigationAction.request, intent)
            decisionHandler(.cancel)
            return
        }

        // target=_blank or window.open() — navigate in the current webview
        if navigationAction.targetFrame == nil,
           navigationAction.request.url != nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        // Cmd+click on a regular link — open in a new tab
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            openInNewTab?(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.isForMainFrame {
            decisionHandler(.allow)
            return
        }

        let mime = navigationResponse.response.mimeType ?? "unknown"
        let canShow = navigationResponse.canShowMIMEType
        let responseURL = navigationResponse.response.url?.absoluteString ?? "nil"

        // Only classify HTTP(S) top-level responses as downloads.
        if let scheme = navigationResponse.response.url?.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            decisionHandler(.allow)
            return
        }

        NSLog("BrowserPanel navigationResponse: url=%@ mime=%@ canShow=%d isMainFrame=%d",
              responseURL, mime, canShow ? 1 : 0,
              navigationResponse.isForMainFrame ? 1 : 0)

        // Check if this response should be treated as a download.
        // Criteria: explicit Content-Disposition: attachment, or a MIME type
        // that WebKit cannot render inline.
        if let response = navigationResponse.response as? HTTPURLResponse {
            let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if contentDisposition.lowercased().hasPrefix("attachment") {
                NSLog("BrowserPanel download: content-disposition=attachment mime=%@ url=%@", mime, responseURL)
                #if DEBUG
                dlog("download.policy=download reason=content-disposition mime=\(mime)")
                #endif
                decisionHandler(.download)
                return
            }
        }

        if !canShow {
            NSLog("BrowserPanel download: cannotShowMIME mime=%@ url=%@", mime, responseURL)
            #if DEBUG
            dlog("download.policy=download reason=cannotShowMIME mime=\(mime)")
            #endif
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        dlog("download.didBecome source=navigationAction")
        #endif
        NSLog("BrowserPanel download didBecome from navigationAction")
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        dlog("download.didBecome source=navigationResponse")
        #endif
        NSLog("BrowserPanel download didBecome from navigationResponse")
        download.delegate = downloadDelegate
    }
}

// MARK: - UI Delegate

private class BrowserUIDelegate: NSObject, WKUIDelegate {
    var openInNewTab: ((URL) -> Void)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?

    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return "The page at \(absolute) says:"
        }
        return "This page says:"
    }

    private func presentDialog(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }
        completion(alert.runModal())
    }

    /// Returning nil tells WebKit not to open a new window.
    /// Cmd+click opens in a new tab; regular target=_blank navigates in-place.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if let requestNavigation {
                let intent: BrowserInsecureHTTPNavigationIntent =
                    navigationAction.modifierFlags.contains(.command) ? .newTab : .currentTab
                requestNavigation(navigationAction.request, intent)
            } else if navigationAction.modifierFlags.contains(.command) {
                openInNewTab?(url)
            } else {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }

    /// Handle <input type="file"> elements by presenting the native file picker.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        presentDialog(alert, for: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        presentDialog(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        presentDialog(alert, for: webView) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(field.stringValue)
            } else {
                completionHandler(nil)
            }
        }
    }
}

// MARK: - Browser Data Import

enum BrowserImportScope: String, CaseIterable, Identifiable {
    case cookiesOnly
    case cookiesAndHistory
    case everything

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cookiesOnly:
            return "Cookies only"
        case .cookiesAndHistory:
            return "Cookies + history"
        case .everything:
            return "Everything"
        }
    }

    var includesCookies: Bool {
        switch self {
        case .cookiesOnly, .cookiesAndHistory, .everything:
            return true
        }
    }

    var includesHistory: Bool {
        switch self {
        case .cookiesOnly:
            return false
        case .cookiesAndHistory, .everything:
            return true
        }
    }
}

enum BrowserImportEngineFamily: String, Hashable {
    case chromium
    case firefox
    case webkit
}

struct BrowserImportBrowserDescriptor: Hashable {
    let id: String
    let displayName: String
    let family: BrowserImportEngineFamily
    let tier: Int
    let bundleIdentifiers: [String]
    let appNames: [String]
    let dataRootRelativePaths: [String]
    let dataArtifactRelativePaths: [String]
    let supportsDataOnlyDetection: Bool
}

struct InstalledBrowserCandidate: Identifiable, Hashable {
    let descriptor: BrowserImportBrowserDescriptor
    let homeDirectoryURL: URL
    let appURL: URL?
    let dataRootURL: URL?
    let profileURLs: [URL]
    let detectionSignals: [String]
    let detectionScore: Int

    var id: String { descriptor.id }
    var displayName: String { descriptor.displayName }
    var family: BrowserImportEngineFamily { descriptor.family }
}

enum InstalledBrowserDetector {
    typealias BundleLookup = (String) -> URL?

    static let allBrowserDescriptors: [BrowserImportBrowserDescriptor] = [
        BrowserImportBrowserDescriptor(
            id: "safari",
            displayName: "Safari",
            family: .webkit,
            tier: 1,
            bundleIdentifiers: ["com.apple.Safari"],
            appNames: ["Safari.app"],
            dataRootRelativePaths: ["Library/Safari"],
            dataArtifactRelativePaths: [
                "Library/Safari/History.db",
                "Library/Cookies/Cookies.binarycookies",
            ],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "google-chrome",
            displayName: "Google Chrome",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["com.google.Chrome"],
            appNames: ["Google Chrome.app"],
            dataRootRelativePaths: ["Library/Application Support/Google/Chrome"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "firefox",
            displayName: "Firefox",
            family: .firefox,
            tier: 1,
            bundleIdentifiers: ["org.mozilla.firefox"],
            appNames: ["Firefox.app"],
            dataRootRelativePaths: ["Library/Application Support/Firefox"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "arc",
            displayName: "Arc",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["company.thebrowser.Browser", "company.thebrowser.arc"],
            appNames: ["Arc.app"],
            dataRootRelativePaths: ["Library/Application Support/Arc"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "brave",
            displayName: "Brave",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["com.brave.Browser"],
            appNames: ["Brave Browser.app"],
            dataRootRelativePaths: ["Library/Application Support/BraveSoftware/Brave-Browser"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "microsoft-edge",
            displayName: "Microsoft Edge",
            family: .chromium,
            tier: 1,
            bundleIdentifiers: ["com.microsoft.edgemac", "com.microsoft.Edge"],
            appNames: ["Microsoft Edge.app"],
            dataRootRelativePaths: ["Library/Application Support/Microsoft Edge"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "zen",
            displayName: "Zen Browser",
            family: .firefox,
            tier: 2,
            bundleIdentifiers: ["app.zen-browser.zen", "app.zen-browser.Zen"],
            appNames: ["Zen Browser.app", "Zen.app"],
            dataRootRelativePaths: ["Library/Application Support/Zen", "Library/Application Support/zen"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "vivaldi",
            displayName: "Vivaldi",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["com.vivaldi.Vivaldi"],
            appNames: ["Vivaldi.app"],
            dataRootRelativePaths: ["Library/Application Support/Vivaldi"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "opera",
            displayName: "Opera",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["com.operasoftware.Opera"],
            appNames: ["Opera.app"],
            dataRootRelativePaths: [
                "Library/Application Support/com.operasoftware.Opera",
                "Library/Application Support/Opera",
            ],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "opera-gx",
            displayName: "Opera GX",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["com.operasoftware.OperaGX"],
            appNames: ["Opera GX.app"],
            dataRootRelativePaths: [
                "Library/Application Support/com.operasoftware.OperaGX",
                "Library/Application Support/Opera GX Stable",
            ],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "orion",
            displayName: "Orion",
            family: .webkit,
            tier: 2,
            bundleIdentifiers: ["com.kagi.kagimacOS", "com.kagi.kagimacos", "com.kagi.orion"],
            appNames: ["Orion.app"],
            dataRootRelativePaths: ["Library/Application Support/Orion"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "dia",
            displayName: "Dia",
            family: .chromium,
            tier: 2,
            bundleIdentifiers: ["company.thebrowser.Dia", "company.thebrowser.dia"],
            appNames: ["Dia.app"],
            dataRootRelativePaths: ["Library/Application Support/Dia"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "perplexity-comet",
            displayName: "Perplexity Comet",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["ai.perplexity.comet"],
            appNames: ["Perplexity Comet.app", "Comet.app"],
            dataRootRelativePaths: ["Library/Application Support/Comet"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "floorp",
            displayName: "Floorp",
            family: .firefox,
            tier: 3,
            bundleIdentifiers: ["one.ablaze.floorp"],
            appNames: ["Floorp.app"],
            dataRootRelativePaths: ["Library/Application Support/Floorp"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "waterfox",
            displayName: "Waterfox",
            family: .firefox,
            tier: 3,
            bundleIdentifiers: ["net.waterfox.waterfox"],
            appNames: ["Waterfox.app"],
            dataRootRelativePaths: ["Library/Application Support/Waterfox"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "sigmaos",
            displayName: "SigmaOS",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["com.feralcat.sigmaos"],
            appNames: ["SigmaOS.app"],
            dataRootRelativePaths: ["Library/Application Support/SigmaOS"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "sidekick",
            displayName: "Sidekick",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["com.meetsidekick.Sidekick", "com.pushplaylabs.sidekick"],
            appNames: ["Sidekick.app"],
            dataRootRelativePaths: ["Library/Application Support/Sidekick"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "helium",
            displayName: "Helium",
            family: .webkit,
            tier: 3,
            bundleIdentifiers: ["com.jadenGeller.Helium", "com.jaden.geller.helium"],
            appNames: ["Helium.app"],
            dataRootRelativePaths: ["Library/Application Support/Helium"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "atlas",
            displayName: "Atlas",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["com.atlas.browser"],
            appNames: ["Atlas.app"],
            dataRootRelativePaths: ["Library/Application Support/Atlas"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "ladybird",
            displayName: "Ladybird",
            family: .webkit,
            tier: 3,
            bundleIdentifiers: ["org.ladybird.Browser", "org.serenityos.ladybird"],
            appNames: ["Ladybird.app"],
            dataRootRelativePaths: ["Library/Application Support/Ladybird"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "chromium",
            displayName: "Chromium",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["org.chromium.Chromium"],
            appNames: ["Chromium.app"],
            dataRootRelativePaths: ["Library/Application Support/Chromium"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: true
        ),
        BrowserImportBrowserDescriptor(
            id: "ungoogled-chromium",
            displayName: "Ungoogled Chromium",
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["org.chromium.ungoogled"],
            appNames: ["Ungoogled Chromium.app"],
            dataRootRelativePaths: ["Library/Application Support/Chromium"],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: false
        ),
    ]

    static func detectInstalledBrowsers(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        bundleLookup: BundleLookup? = nil,
        applicationSearchDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [InstalledBrowserCandidate] {
        let lookup = bundleLookup ?? { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        let appSearchDirectories = applicationSearchDirectories ?? defaultApplicationSearchDirectories(homeDirectoryURL: homeDirectoryURL)

        let candidates = allBrowserDescriptors.compactMap { descriptor -> InstalledBrowserCandidate? in
            let appDetection = detectApplication(
                descriptor: descriptor,
                appSearchDirectories: appSearchDirectories,
                bundleLookup: lookup,
                fileManager: fileManager
            )

            let dataDetection = detectData(
                descriptor: descriptor,
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )

            if appDetection.url == nil,
               !descriptor.supportsDataOnlyDetection {
                return nil
            }

            let hasData = dataDetection.dataRootURL != nil || !dataDetection.profileURLs.isEmpty || !dataDetection.artifactHits.isEmpty
            guard appDetection.url != nil || hasData else {
                return nil
            }

            var score = 0
            if appDetection.url != nil {
                score += 80
            }
            if dataDetection.dataRootURL != nil {
                score += 24
            }
            score += min(24, dataDetection.profileURLs.count * 6)
            score += min(16, dataDetection.artifactHits.count * 4)

            var signals: [String] = []
            signals.append(contentsOf: appDetection.signals)
            if let root = dataDetection.dataRootURL {
                signals.append("data:\(root.lastPathComponent)")
            }
            if !dataDetection.profileURLs.isEmpty {
                signals.append("profiles:\(dataDetection.profileURLs.count)")
            }
            if !dataDetection.artifactHits.isEmpty {
                signals.append(contentsOf: dataDetection.artifactHits.map { "artifact:\($0)" })
            }

            return InstalledBrowserCandidate(
                descriptor: descriptor,
                homeDirectoryURL: homeDirectoryURL,
                appURL: appDetection.url,
                dataRootURL: dataDetection.dataRootURL,
                profileURLs: dataDetection.profileURLs,
                detectionSignals: signals,
                detectionScore: score
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.detectionScore != rhs.detectionScore {
                return lhs.detectionScore > rhs.detectionScore
            }
            if lhs.descriptor.tier != rhs.descriptor.tier {
                return lhs.descriptor.tier < rhs.descriptor.tier
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func summaryText(for browsers: [InstalledBrowserCandidate], limit: Int = 4) -> String {
        guard !browsers.isEmpty else { return "No supported browsers detected." }
        let names = browsers.map(\.displayName)
        if names.count <= limit {
            return "Detected: \(names.joined(separator: ", "))."
        }
        let shown = names.prefix(limit).joined(separator: ", ")
        return "Detected: \(shown), +\(names.count - limit) more."
    }

    private static func detectApplication(
        descriptor: BrowserImportBrowserDescriptor,
        appSearchDirectories: [URL],
        bundleLookup: BundleLookup,
        fileManager: FileManager
    ) -> (url: URL?, signals: [String]) {
        for bundleIdentifier in descriptor.bundleIdentifiers {
            if let appURL = bundleLookup(bundleIdentifier) {
                return (appURL, ["bundle:\(bundleIdentifier)"])
            }
        }

        for appName in descriptor.appNames {
            for directory in appSearchDirectories {
                let appURL = directory.appendingPathComponent(appName, isDirectory: true)
                if fileManager.fileExists(atPath: appURL.path) {
                    return (appURL, ["app:\(appName)"])
                }
            }
        }

        return (nil, [])
    }

    private static func detectData(
        descriptor: BrowserImportBrowserDescriptor,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> (dataRootURL: URL?, profileURLs: [URL], artifactHits: [String]) {
        var bestRootURL: URL?
        var bestProfiles: [URL] = []
        var bestArtifacts: [String] = []

        for relativePath in descriptor.dataRootRelativePaths {
            let rootURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: rootURL.path) else { continue }

            let profiles: [URL]
            switch descriptor.family {
            case .chromium:
                profiles = chromiumProfileURLs(rootURL: rootURL, fileManager: fileManager)
            case .firefox:
                profiles = firefoxProfileURLs(rootURL: rootURL, fileManager: fileManager)
            case .webkit:
                profiles = []
            }

            let score = (profiles.count * 10) + 8
            let currentScore = (bestProfiles.count * 10) + (bestRootURL == nil ? 0 : 8)
            if score > currentScore {
                bestRootURL = rootURL
                bestProfiles = profiles
            }
        }

        var artifactHits: [String] = []
        for relativePath in descriptor.dataArtifactRelativePaths {
            let artifactURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: artifactURL.path) {
                artifactHits.append(artifactURL.lastPathComponent)
            }
        }

        if !artifactHits.isEmpty {
            bestArtifacts = artifactHits
            if bestRootURL == nil,
               let rootPath = descriptor.dataRootRelativePaths.first {
                let rootURL = homeDirectoryURL.appendingPathComponent(rootPath, isDirectory: true)
                if fileManager.fileExists(atPath: rootURL.path) {
                    bestRootURL = rootURL
                }
            }
        }

        return (
            dataRootURL: bestRootURL,
            profileURLs: dedupedCanonicalURLs(bestProfiles),
            artifactHits: bestArtifacts
        )
    }

    private static func chromiumProfileURLs(
        rootURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        var profiles: [URL] = []
        if looksLikeChromiumProfile(rootURL: rootURL, fileManager: fileManager) {
            profiles.append(rootURL)
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = child.lastPathComponent
            let isLikelyProfile =
                name == "Default" ||
                name.hasPrefix("Profile ") ||
                name.hasPrefix("Guest Profile") ||
                name.hasPrefix("Person ")
            if isLikelyProfile && looksLikeChromiumProfile(rootURL: child, fileManager: fileManager) {
                profiles.append(child)
            }
        }

        profiles = dedupedCanonicalURLs(profiles)
        return profiles.sorted {
            profileRecency(for: $0, preferredFiles: ["History", "Cookies"], fileManager: fileManager) >
                profileRecency(for: $1, preferredFiles: ["History", "Cookies"], fileManager: fileManager)
        }
    }

    private static func firefoxProfileURLs(
        rootURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        var profiles = firefoxProfilesFromINI(rootURL: rootURL, fileManager: fileManager)

        let likelyProfileRoots = [
            rootURL.appendingPathComponent("Profiles", isDirectory: true),
            rootURL,
        ]

        for directory in likelyProfileRoots where fileManager.fileExists(atPath: directory.path) {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if looksLikeFirefoxProfile(rootURL: child, fileManager: fileManager) {
                    profiles.append(child)
                }
            }
        }

        profiles = dedupedCanonicalURLs(profiles)
        return profiles.sorted {
            profileRecency(for: $0, preferredFiles: ["places.sqlite", "cookies.sqlite"], fileManager: fileManager) >
                profileRecency(for: $1, preferredFiles: ["places.sqlite", "cookies.sqlite"], fileManager: fileManager)
        }
    }

    private static func firefoxProfilesFromINI(
        rootURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let iniURL = rootURL.appendingPathComponent("profiles.ini", isDirectory: false)
        guard let contents = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return []
        }

        var sections: [[String: String]] = []
        var current: [String: String] = [:]

        func flushCurrent() {
            if !current.isEmpty {
                sections.append(current)
                current.removeAll()
            }
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                flushCurrent()
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            current[key] = value
        }
        flushCurrent()

        var urls: [URL] = []
        for section in sections {
            guard let pathValue = section["Path"], !pathValue.isEmpty else { continue }
            let isRelative = section["IsRelative"] != "0"
            let profileURL: URL
            if isRelative {
                profileURL = rootURL.appendingPathComponent(pathValue, isDirectory: true)
            } else {
                profileURL = URL(fileURLWithPath: pathValue, isDirectory: true)
            }
            if looksLikeFirefoxProfile(rootURL: profileURL, fileManager: fileManager) {
                urls.append(profileURL)
            }
        }
        return urls
    }

    private static func looksLikeChromiumProfile(rootURL: URL, fileManager: FileManager) -> Bool {
        let historyURL = rootURL.appendingPathComponent("History", isDirectory: false)
        let cookiesURL = rootURL.appendingPathComponent("Cookies", isDirectory: false)
        return fileManager.fileExists(atPath: historyURL.path) || fileManager.fileExists(atPath: cookiesURL.path)
    }

    private static func looksLikeFirefoxProfile(rootURL: URL, fileManager: FileManager) -> Bool {
        let historyURL = rootURL.appendingPathComponent("places.sqlite", isDirectory: false)
        let cookiesURL = rootURL.appendingPathComponent("cookies.sqlite", isDirectory: false)
        return fileManager.fileExists(atPath: historyURL.path) || fileManager.fileExists(atPath: cookiesURL.path)
    }

    private static func profileRecency(
        for profileURL: URL,
        preferredFiles: [String],
        fileManager: FileManager
    ) -> TimeInterval {
        var latest: TimeInterval = 0
        for fileName in preferredFiles {
            let url = profileURL.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else {
                continue
            }
            latest = max(latest, date.timeIntervalSince1970)
        }
        return latest
    }

    private static func defaultApplicationSearchDirectories(homeDirectoryURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications/Setapp", isDirectory: true),
        ]
    }

    private static func dedupedCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted {
                result.append(url)
            }
        }
        return result
    }
}

struct BrowserImportOutcome {
    let browserName: String
    let scope: BrowserImportScope
    let domainFilters: [String]
    let importedCookies: Int
    let skippedCookies: Int
    let importedHistoryEntries: Int
    let warnings: [String]
}

enum BrowserDataImporter {
    private struct CookieImportResult {
        var importedCount: Int = 0
        var skippedCount: Int = 0
        var warnings: [String] = []
    }

    private struct HistoryImportResult {
        var importedCount: Int = 0
        var warnings: [String] = []
    }

    private struct HistoryRow {
        let url: String
        let title: String?
        let visitCount: Int
        let lastVisited: Date
    }

    static func parseDomainFilters(_ raw: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        for token in raw.components(separatedBy: separators) {
            var value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("*.") {
                value.removeFirst(2)
            }
            while value.hasPrefix(".") {
                value.removeFirst()
            }
            guard !value.isEmpty else { continue }
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    static func importData(
        from browser: InstalledBrowserCandidate,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcome {
        var cookieResult = CookieImportResult()
        if scope.includesCookies {
            cookieResult = await importCookies(from: browser, domainFilters: domainFilters)
        }

        var historyResult = HistoryImportResult()
        if scope.includesHistory {
            historyResult = await importHistory(from: browser, domainFilters: domainFilters)
        }

        var warnings = cookieResult.warnings
        warnings.append(contentsOf: historyResult.warnings)
        if scope == .everything {
            warnings.append("Bookmarks/settings import is not implemented yet; imported cookies and history only.")
        }

        return BrowserImportOutcome(
            browserName: browser.displayName,
            scope: scope,
            domainFilters: domainFilters,
            importedCookies: cookieResult.importedCount,
            skippedCookies: cookieResult.skippedCount,
            importedHistoryEntries: historyResult.importedCount,
            warnings: warnings
        )
    }

    private static func importCookies(
        from browser: InstalledBrowserCandidate,
        domainFilters: [String]
    ) async -> CookieImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxCookies(from: browser, domainFilters: domainFilters)
        case .chromium:
            return await importChromiumCookies(from: browser, domainFilters: domainFilters)
        case .webkit:
            if browser.descriptor.id == "safari" {
                return CookieImportResult(
                    importedCount: 0,
                    skippedCount: 0,
                    warnings: [
                        "Safari cookies are stored in Cookies.binarycookies and are not yet supported by this importer."
                    ]
                )
            }
            return CookieImportResult(
                importedCount: 0,
                skippedCount: 0,
                warnings: [
                    "\(browser.displayName) cookie import is not implemented yet."
                ]
            )
        }
    }

    private static func importHistory(
        from browser: InstalledBrowserCandidate,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxHistory(from: browser, domainFilters: domainFilters)
        case .chromium:
            return await importChromiumHistory(from: browser, domainFilters: domainFilters)
        case .webkit:
            return await importWebKitHistory(from: browser, domainFilters: domainFilters)
        }
    }

    private static func importFirefoxCookies(
        from browser: InstalledBrowserCandidate,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []

        let databaseURLs = browser.profileURLs.map {
            $0.appendingPathComponent("cookies.sqlite", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies"
                ) { statement in
                    let host = sqliteColumnText(statement, index: 0) ?? ""
                    let name = sqliteColumnText(statement, index: 1) ?? ""
                    let value = sqliteColumnText(statement, index: 2) ?? ""
                    let path = sqliteColumnText(statement, index: 3) ?? "/"
                    let expiry = sqliteColumnInt64(statement, index: 4)
                    let isSecure = sqliteColumnInt64(statement, index: 5) != 0

                    guard !name.isEmpty else { return }
                    guard domainMatches(host: host, filters: domainFilters) else { return }

                    var properties: [HTTPCookiePropertyKey: Any] = [
                        .domain: host,
                        .path: path.isEmpty ? "/" : path,
                        .name: name,
                        .value: value,
                    ]
                    if isSecure {
                        properties[.secure] = "TRUE"
                    }
                    if expiry > 0 {
                        properties[.expires] = Date(timeIntervalSince1970: TimeInterval(expiry))
                    }
                    if let cookie = HTTPCookie(properties: properties) {
                        cookies.append(cookie)
                    }
                }
            } catch {
                warnings.append("Failed reading Firefox cookies at \(databaseURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies)
        return CookieImportResult(importedCount: importedCount, skippedCount: max(0, dedupedCookies.count - importedCount), warnings: warnings)
    }

    private static func importChromiumCookies(
        from browser: InstalledBrowserCandidate,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []
        var skippedEncryptedCookies = 0

        let databaseURLs = browser.profileURLs.map {
            $0.appendingPathComponent("Cookies", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: "SELECT host_key, name, value, path, expires_utc, is_secure, encrypted_value FROM cookies"
                ) { statement in
                    let host = sqliteColumnText(statement, index: 0) ?? ""
                    let name = sqliteColumnText(statement, index: 1) ?? ""
                    let value = sqliteColumnText(statement, index: 2) ?? ""
                    let path = sqliteColumnText(statement, index: 3) ?? "/"
                    let expiresUTC = sqliteColumnInt64(statement, index: 4)
                    let isSecure = sqliteColumnInt64(statement, index: 5) != 0
                    let encryptedLength = sqliteColumnBytes(statement, index: 6)

                    guard !name.isEmpty else { return }
                    guard domainMatches(host: host, filters: domainFilters) else { return }

                    let usableValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if usableValue.isEmpty && encryptedLength > 0 {
                        skippedEncryptedCookies += 1
                        return
                    }

                    var properties: [HTTPCookiePropertyKey: Any] = [
                        .domain: host,
                        .path: path.isEmpty ? "/" : path,
                        .name: name,
                        .value: usableValue,
                    ]
                    if isSecure {
                        properties[.secure] = "TRUE"
                    }
                    if let expiresDate = chromiumDate(fromWebKitMicroseconds: expiresUTC) {
                        properties[.expires] = expiresDate
                    }
                    if let cookie = HTTPCookie(properties: properties) {
                        cookies.append(cookie)
                    }
                }
            } catch {
                warnings.append("Failed reading \(browser.displayName) cookies at \(databaseURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies)
        if skippedEncryptedCookies > 0 {
            warnings.append("Skipped \(skippedEncryptedCookies) encrypted cookies that require Keychain decryption.")
        }
        let skippedCount = max(0, dedupedCookies.count - importedCount) + skippedEncryptedCookies
        return CookieImportResult(importedCount: importedCount, skippedCount: skippedCount, warnings: warnings)
    }

    private static func importFirefoxHistory(
        from browser: InstalledBrowserCandidate,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = browser.profileURLs.map {
            $0.appendingPathComponent("places.sqlite", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT url, title, visit_count, last_visit_date
                    FROM moz_places
                    WHERE url LIKE 'http%'
                    ORDER BY last_visit_date DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitMicros = sqliteColumnInt64(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = firefoxDate(fromUnixMicroseconds: lastVisitMicros) ?? Date()
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append("Failed reading Firefox history at \(databaseURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let importedCount = await mergeHistoryRows(rows)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importChromiumHistory(
        from browser: InstalledBrowserCandidate,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = browser.profileURLs.map {
            $0.appendingPathComponent("History", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT url, title, visit_count, last_visit_time
                    FROM urls
                    WHERE url LIKE 'http%'
                    ORDER BY last_visit_time DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitMicros = sqliteColumnInt64(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = chromiumDate(fromWebKitMicroseconds: lastVisitMicros) ?? Date()
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append("Failed reading \(browser.displayName) history at \(databaseURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let importedCount = await mergeHistoryRows(rows)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importWebKitHistory(
        from browser: InstalledBrowserCandidate,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        var candidateDatabaseURLs: [URL] = []
        if let dataRootURL = browser.dataRootURL {
            candidateDatabaseURLs.append(dataRootURL.appendingPathComponent("History.db", isDirectory: false))
        }
        if browser.descriptor.id == "safari" {
            candidateDatabaseURLs.append(
                browser.homeDirectoryURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Safari", isDirectory: true)
                    .appendingPathComponent("History.db", isDirectory: false)
            )
        }
        let uniqueURLs = dedupedCanonicalURLs(candidateDatabaseURLs).filter { fileManager.fileExists(atPath: $0.path) }

        if uniqueURLs.isEmpty {
            return HistoryImportResult(importedCount: 0, warnings: ["No history database found for \(browser.displayName)."])
        }

        for databaseURL in uniqueURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT history_items.url,
                           history_items.title,
                           COUNT(history_visits.id) AS visit_count,
                           MAX(history_visits.visit_time) AS last_visit_time
                    FROM history_items
                    JOIN history_visits
                      ON history_items.id = history_visits.history_item
                    GROUP BY history_items.url
                    ORDER BY last_visit_time DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitReferenceSeconds = sqliteColumnDouble(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = Date(timeIntervalSinceReferenceDate: lastVisitReferenceSeconds)
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append("Failed reading \(browser.displayName) history at \(databaseURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let importedCount = await mergeHistoryRows(rows)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func mergeHistoryRows(_ rows: [HistoryRow]) async -> Int {
        guard !rows.isEmpty else { return 0 }
        return await MainActor.run {
            let entries = rows.compactMap { row -> BrowserHistoryStore.Entry? in
                guard let parsedURL = URL(string: row.url),
                      let scheme = parsedURL.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    return nil
                }
                let trimmedTitle = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return BrowserHistoryStore.Entry(
                    id: UUID(),
                    url: parsedURL.absoluteString,
                    title: trimmedTitle,
                    lastVisited: row.lastVisited,
                    visitCount: max(1, row.visitCount)
                )
            }
            return BrowserHistoryStore.shared.mergeImportedEntries(entries)
        }
    }

    private static func setCookiesInStore(_ cookies: [HTTPCookie]) async -> Int {
        guard !cookies.isEmpty else { return 0 }
        let store = WKWebsiteDataStore.default().httpCookieStore
        var importedCount = 0
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    importedCount += 1
                    continuation.resume()
                }
            }
        }
        return importedCount
    }

    private static func dedupeCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var dedupedByKey: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let key = "\(cookie.name.lowercased())|\(cookie.domain.lowercased())|\(cookie.path)"
            if let existing = dedupedByKey[key] {
                let existingExpiry = existing.expiresDate ?? .distantPast
                let candidateExpiry = cookie.expiresDate ?? .distantPast
                if candidateExpiry >= existingExpiry {
                    dedupedByKey[key] = cookie
                }
            } else {
                dedupedByKey[key] = cookie
            }
        }
        return Array(dedupedByKey.values)
    }

    private static func domainMatches(host: String, filters: [String]) -> Bool {
        if filters.isEmpty { return true }
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalizedHost.hasPrefix(".") {
            normalizedHost.removeFirst()
        }
        guard !normalizedHost.isEmpty else { return false }
        for filter in filters {
            if normalizedHost == filter { return true }
            if normalizedHost.hasSuffix(".\(filter)") { return true }
        }
        return false
    }

    private static func chromiumDate(fromWebKitMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let unixSeconds = (Double(rawValue) / 1_000_000.0) - 11_644_473_600.0
        guard unixSeconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func firefoxDate(fromUnixMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let seconds = Double(rawValue) / 1_000_000.0
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func querySQLiteRows(
        sourceDatabaseURL: URL,
        sql: String,
        rowHandler: (OpaquePointer) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-browser-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let snapshotURL = tempRoot.appendingPathComponent(sourceDatabaseURL.lastPathComponent, isDirectory: false)
        try fileManager.copyItem(at: sourceDatabaseURL, to: snapshotURL)

        let walSourceURL = URL(fileURLWithPath: "\(sourceDatabaseURL.path)-wal")
        let walSnapshotURL = URL(fileURLWithPath: "\(snapshotURL.path)-wal")
        if fileManager.fileExists(atPath: walSourceURL.path) {
            try? fileManager.copyItem(at: walSourceURL, to: walSnapshotURL)
        }
        let shmSourceURL = URL(fileURLWithPath: "\(sourceDatabaseURL.path)-shm")
        let shmSnapshotURL = URL(fileURLWithPath: "\(snapshotURL.path)-shm")
        if fileManager.fileExists(atPath: shmSourceURL.path) {
            try? fileManager.copyItem(at: shmSourceURL, to: shmSnapshotURL)
        }

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(snapshotURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            let message = sqliteMessage(from: database) ?? "unknown SQLite open failure"
            sqlite3_close(database)
            throw NSError(domain: "BrowserDataImporter", code: Int(openCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            let message = sqliteMessage(from: database) ?? "unknown SQLite prepare failure"
            sqlite3_finalize(statement)
            throw NSError(domain: "BrowserDataImporter", code: Int(prepareCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_ROW {
                try rowHandler(statement)
                continue
            }
            if stepCode == SQLITE_DONE {
                break
            }
            let message = sqliteMessage(from: database) ?? "unknown SQLite step failure"
            throw NSError(domain: "BrowserDataImporter", code: Int(stepCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private static func sqliteMessage(from database: OpaquePointer?) -> String? {
        guard let database, let cString = sqlite3_errmsg(database) else { return nil }
        return String(cString: cString)
    }

    private static func sqliteColumnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cValue = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cValue)
    }

    private static func sqliteColumnInt64(_ statement: OpaquePointer, index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private static func sqliteColumnDouble(_ statement: OpaquePointer, index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    private static func sqliteColumnBytes(_ statement: OpaquePointer, index: Int32) -> Int {
        Int(sqlite3_column_bytes(statement, index))
    }

    private static func dedupedCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted {
                result.append(url)
            }
        }
        return result
    }
}

@MainActor
final class BrowserDataImportCoordinator {
    static let shared = BrowserDataImportCoordinator()

    private var importInProgress = false

    private init() {}

    func presentImportDialog() {
        presentImportDialog(prefilledBrowsers: nil)
    }

    private struct ImportSelection {
        let browser: InstalledBrowserCandidate
        let scope: BrowserImportScope
        let domainFilters: [String]
    }

    private func presentImportDialog(prefilledBrowsers: [InstalledBrowserCandidate]?) {
        guard !importInProgress else { return }
        let browsers = prefilledBrowsers ?? InstalledBrowserDetector.detectInstalledBrowsers()
        guard !browsers.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "No supported browsers detected"
            alert.informativeText = "cmux could not find installed browser profiles to import from."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        guard let selection = promptForSelection(browsers: browsers) else { return }
        importInProgress = true

        let progressWindow = showProgressWindow(
            title: "Importing Browser Data",
            message: "Importing \(selection.scope.displayName.lowercased()) from \(selection.browser.displayName)…"
        )

        Task.detached(priority: .userInitiated) {
            let outcome = await BrowserDataImporter.importData(
                from: selection.browser,
                scope: selection.scope,
                domainFilters: selection.domainFilters
            )

            await MainActor.run {
                self.hideProgressWindow(progressWindow)
                self.presentOutcome(outcome)
                self.importInProgress = false
            }
        }
    }

    private func promptForSelection(browsers: [InstalledBrowserCandidate]) -> ImportSelection? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Import Browser Data"
        alert.informativeText = "Choose a browser and what to import."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let browserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for browser in browsers {
            browserPopup.addItem(withTitle: browser.displayName)
        }
        browserPopup.selectItem(at: 0)

        let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for scope in BrowserImportScope.allCases {
            scopePopup.addItem(withTitle: scope.displayName)
            scopePopup.item(at: scopePopup.numberOfItems - 1)?.representedObject = scope.rawValue
        }
        if let defaultIndex = BrowserImportScope.allCases.firstIndex(of: .cookiesAndHistory) {
            scopePopup.selectItem(at: defaultIndex)
        }

        let domainField = NSTextField(frame: .zero)
        domainField.placeholderString = "Optional domains (comma or space separated)"
        domainField.stringValue = ""

        let browserRow = NSStackView()
        browserRow.orientation = .horizontal
        browserRow.spacing = 8
        browserRow.alignment = .centerY
        let browserLabel = NSTextField(labelWithString: "Browser")
        browserLabel.alignment = .right
        browserLabel.frame.size.width = 72
        browserRow.addArrangedSubview(browserLabel)
        browserRow.addArrangedSubview(browserPopup)

        let scopeRow = NSStackView()
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8
        scopeRow.alignment = .centerY
        let scopeLabel = NSTextField(labelWithString: "Import")
        scopeLabel.alignment = .right
        scopeLabel.frame.size.width = 72
        scopeRow.addArrangedSubview(scopeLabel)
        scopeRow.addArrangedSubview(scopePopup)

        let domainRow = NSStackView()
        domainRow.orientation = .horizontal
        domainRow.spacing = 8
        domainRow.alignment = .centerY
        let domainLabel = NSTextField(labelWithString: "Domains")
        domainLabel.alignment = .right
        domainLabel.frame.size.width = 72
        domainRow.addArrangedSubview(domainLabel)
        domainRow.addArrangedSubview(domainField)

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.spacing = 8
        accessory.alignment = .leading
        accessory.addArrangedSubview(browserRow)
        accessory.addArrangedSubview(scopeRow)
        accessory.addArrangedSubview(domainRow)
        accessory.setFrameSize(NSSize(width: 420, height: 108))
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let browserIndex = max(0, min(browserPopup.indexOfSelectedItem, browsers.count - 1))
        let selectedBrowser = browsers[browserIndex]
        let selectedScopeRaw = scopePopup.selectedItem?.representedObject as? String ?? BrowserImportScope.cookiesAndHistory.rawValue
        let selectedScope = BrowserImportScope(rawValue: selectedScopeRaw) ?? .cookiesAndHistory
        let domainFilters = BrowserDataImporter.parseDomainFilters(domainField.stringValue)

        return ImportSelection(
            browser: selectedBrowser,
            scope: selectedScope,
            domainFilters: domainFilters
        )
    }

    private func showProgressWindow(title: String, message: String) -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 122),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 122))

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 50, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        content.addSubview(spinner)

        let titleLabel = NSTextField(labelWithString: message)
        titleLabel.frame = NSRect(x: 52, y: 56, width: 340, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        content.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "This can take a few seconds for large profiles.")
        subtitleLabel.frame = NSRect(x: 52, y: 34, width: 340, height: 16)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        content.addSubview(subtitleLabel)

        window.contentView = content

        if let keyWindow = NSApp.keyWindow {
            keyWindow.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        return window
    }

    private func hideProgressWindow(_ window: NSWindow) {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    private func presentOutcome(_ outcome: BrowserImportOutcome) {
        var lines: [String] = []
        lines.append("Browser: \(outcome.browserName)")
        lines.append("Scope: \(outcome.scope.displayName)")
        lines.append("Imported cookies: \(outcome.importedCookies)")
        if outcome.skippedCookies > 0 {
            lines.append("Skipped cookies: \(outcome.skippedCookies)")
        }
        if outcome.scope.includesHistory {
            lines.append("Imported history entries: \(outcome.importedHistoryEntries)")
        }
        if !outcome.domainFilters.isEmpty {
            lines.append("Domain filter: \(outcome.domainFilters.joined(separator: ", "))")
        }
        if !outcome.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            for warning in outcome.warnings {
                lines.append("- \(warning)")
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Browser data import complete"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
