import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

fileprivate func dedupedCanonicalURLs(_ urls: [URL]) -> [URL] {
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

struct BrowserProxyEndpoint: Equatable {
    let host: String
    let port: Int
}

struct BrowserRemoteWorkspaceStatus: Equatable {
    let target: String
    let connectionState: WorkspaceRemoteConnectionState
    let heartbeatCount: Int
    let lastHeartbeatAt: Date?
}

enum GhosttyBackgroundTheme {
    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    static func color(backgroundColor: NSColor, opacity: Double) -> NSColor {
        backgroundColor.withAlphaComponent(clampedOpacity(opacity))
    }

    static func color(
        from notification: Notification?,
        fallbackColor: NSColor,
        fallbackOpacity: Double
    ) -> NSColor {
        let userInfo = notification?.userInfo
        let backgroundColor =
            (userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)
            ?? fallbackColor

        let opacity: Double
        if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? Double {
            opacity = value
        } else if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? NSNumber {
            opacity = value.doubleValue
        } else {
            opacity = fallbackOpacity
        }

        return color(backgroundColor: backgroundColor, opacity: opacity)
    }

    static func color(from notification: Notification?) -> NSColor {
        color(
            from: notification,
            fallbackColor: GhosttyApp.shared.defaultBackgroundColor,
            fallbackOpacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
    }

    static func currentColor() -> NSColor {
        color(
            backgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            opacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
    }
}

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckduckgo
    case bing
    case kagi
    case startpage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        case .startpage: return "Startpage"
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
        case .kagi:
            components = URLComponents(string: "https://kagi.com/search")
        case .startpage:
            components = URLComponents(string: "https://www.startpage.com/do/dsearch")
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

enum BrowserThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "theme.system", defaultValue: "System")
        case .light:
            return String(localized: "theme.light", defaultValue: "Light")
        case .dark:
            return String(localized: "theme.dark", defaultValue: "Dark")
        }
    }

    var iconName: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}

enum BrowserThemeSettings {
    static let modeKey = "browserThemeMode"
    static let legacyForcedDarkModeEnabledKey = "browserForcedDarkModeEnabled"
    static let defaultMode: BrowserThemeMode = .system

    static func mode(for rawValue: String?) -> BrowserThemeMode {
        guard let rawValue, let mode = BrowserThemeMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    static func mode(defaults: UserDefaults = .standard) -> BrowserThemeMode {
        let resolvedMode = mode(for: defaults.string(forKey: modeKey))
        if defaults.string(forKey: modeKey) != nil {
            return resolvedMode
        }

        // Migrate the legacy bool toggle only when the new mode key is unset.
        if defaults.object(forKey: legacyForcedDarkModeEnabledKey) != nil {
            let migratedMode: BrowserThemeMode = defaults.bool(forKey: legacyForcedDarkModeEnabledKey) ? .dark : .system
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return migratedMode
        }

        return defaultMode
    }
}

enum BrowserImportHintVariant: String, CaseIterable, Identifiable {
    case inlineStrip
    case floatingCard
    case toolbarChip
    case settingsOnly

    var id: String { rawValue }
}

enum BrowserImportHintBlankTabPlacement: Equatable {
    case hidden
    case inlineStrip
    case floatingCard
    case toolbarChip
}

enum BrowserImportHintSettingsStatus: Equatable {
    case visible
    case hidden
    case settingsOnly
}

struct BrowserImportHintPresentation: Equatable {
    let blankTabPlacement: BrowserImportHintBlankTabPlacement
    let settingsStatus: BrowserImportHintSettingsStatus

    init(
        variant: BrowserImportHintVariant,
        showOnBlankTabs: Bool,
        isDismissed: Bool
    ) {
        if variant == .settingsOnly {
            blankTabPlacement = .hidden
            settingsStatus = .settingsOnly
            return
        }

        if !showOnBlankTabs || isDismissed {
            blankTabPlacement = .hidden
            settingsStatus = .hidden
            return
        }

        switch variant {
        case .inlineStrip:
            blankTabPlacement = .inlineStrip
        case .floatingCard:
            blankTabPlacement = .floatingCard
        case .toolbarChip:
            blankTabPlacement = .toolbarChip
        case .settingsOnly:
            blankTabPlacement = .hidden
        }
        settingsStatus = .visible
    }
}

enum BrowserImportHintSettings {
    static let variantKey = "browserImportHintVariant"
    static let showOnBlankTabsKey = "browserImportHintShowOnBlankTabs"
    static let dismissedKey = "browserImportHintDismissed"
    static let defaultVariant: BrowserImportHintVariant = .toolbarChip
    static let defaultShowOnBlankTabs = true
    static let defaultDismissed = false

    static func variant(for rawValue: String?) -> BrowserImportHintVariant {
        guard let rawValue, let variant = BrowserImportHintVariant(rawValue: rawValue) else {
            return defaultVariant
        }
        return variant
    }

    static func variant(defaults: UserDefaults = .standard) -> BrowserImportHintVariant {
        variant(for: defaults.string(forKey: variantKey))
    }

    static func showOnBlankTabs(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showOnBlankTabsKey) == nil {
            return defaultShowOnBlankTabs
        }
        return defaults.bool(forKey: showOnBlankTabsKey)
    }

    static func isDismissed(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dismissedKey) == nil {
            return defaultDismissed
        }
        return defaults.bool(forKey: dismissedKey)
    }

    static func presentation(defaults: UserDefaults = .standard) -> BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: variant(defaults: defaults),
            showOnBlankTabs: showOnBlankTabs(defaults: defaults),
            isDismissed: isDismissed(defaults: defaults)
        )
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.set(defaultVariant.rawValue, forKey: variantKey)
        defaults.set(defaultShowOnBlankTabs, forKey: showOnBlankTabsKey)
        defaults.set(defaultDismissed, forKey: dismissedKey)
    }
}

struct BrowserProfileDefinition: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    let createdAt: Date
    let isBuiltInDefault: Bool

    var slug: String {
        if isBuiltInDefault {
            return "default"
        }

        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? id.uuidString.lowercased() : normalized
    }
}

@MainActor
final class BrowserProfileStore: ObservableObject {
    static let shared = BrowserProfileStore()

    private static let profilesDefaultsKey = "browserProfiles.v1"
    private static let lastUsedProfileDefaultsKey = "browserProfiles.lastUsed"
    private static let builtInDefaultProfileID = UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!

    @Published private(set) var profiles: [BrowserProfileDefinition] = []
    @Published private(set) var lastUsedProfileID: UUID = builtInDefaultProfileID

    private let defaults: UserDefaults
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private var historyStores: [UUID: BrowserHistoryStore] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var builtInDefaultProfileID: UUID {
        Self.builtInDefaultProfileID
    }

    var effectiveLastUsedProfileID: UUID {
        profileDefinition(id: lastUsedProfileID) != nil ? lastUsedProfileID : Self.builtInDefaultProfileID
    }

    func profileDefinition(id: UUID) -> BrowserProfileDefinition? {
        profiles.first(where: { $0.id == id })
    }

    func displayName(for id: UUID) -> String {
        profileDefinition(id: id)?.displayName
        ?? String(localized: "browser.profile.default", defaultValue: "Default")
    }

    func createProfile(named rawName: String) -> BrowserProfileDefinition? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let profile = BrowserProfileDefinition(
            id: UUID(),
            displayName: name,
            createdAt: Date(),
            isBuiltInDefault: false
        )
        profiles.append(profile)
        profiles.sort {
            if $0.isBuiltInDefault != $1.isBuiltInDefault {
                return $0.isBuiltInDefault && !$1.isBuiltInDefault
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persist()
        noteUsed(profile.id)
        return profile
    }

    func renameProfile(id: UUID, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isBuiltInDefault else {
            return false
        }
        profiles[index].displayName = name
        profiles.sort {
            if $0.isBuiltInDefault != $1.isBuiltInDefault {
                return $0.isBuiltInDefault && !$1.isBuiltInDefault
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persist()
        return true
    }

    func canRenameProfile(id: UUID) -> Bool {
        guard let profile = profileDefinition(id: id) else { return false }
        return !profile.isBuiltInDefault
    }

    func noteUsed(_ id: UUID) {
        guard profileDefinition(id: id) != nil else { return }
        if lastUsedProfileID != id {
            lastUsedProfileID = id
            defaults.set(id.uuidString, forKey: Self.lastUsedProfileDefaultsKey)
        }
    }

    func websiteDataStore(for profileID: UUID) -> WKWebsiteDataStore {
        if profileID == Self.builtInDefaultProfileID {
            return .default()
        }
        if let existing = dataStores[profileID] {
            return existing
        }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        dataStores[profileID] = store
        return store
    }

    func historyStore(for profileID: UUID) -> BrowserHistoryStore {
        if profileID == Self.builtInDefaultProfileID {
            return .shared
        }
        if let existing = historyStores[profileID] {
            return existing
        }
        let store = BrowserHistoryStore(fileURL: historyFileURL(for: profileID))
        historyStores[profileID] = store
        return store
    }

    func historyFileURL(for profileID: UUID) -> URL? {
        if profileID == Self.builtInDefaultProfileID {
            return BrowserHistoryStore.defaultHistoryFileURLForCurrentBundle()
        }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let namespace = BrowserHistoryStore.normalizedBrowserHistoryNamespaceForBundleIdentifier(bundleId)
        let profilesDir = appSupport
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("browser_profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        return profilesDir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    func flushPendingSaves() {
        BrowserHistoryStore.shared.flushPendingSaves()
        for store in historyStores.values {
            store.flushPendingSaves()
        }
    }

    private func load() {
        let builtInDefaultProfile = BrowserProfileDefinition(
            id: Self.builtInDefaultProfileID,
            displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
            createdAt: Date(timeIntervalSince1970: 0),
            isBuiltInDefault: true
        )

        if let data = defaults.data(forKey: Self.profilesDefaultsKey),
           let decoded = try? JSONDecoder().decode([BrowserProfileDefinition].self, from: data),
           !decoded.isEmpty {
            var resolvedProfiles = decoded.filter { $0.id != Self.builtInDefaultProfileID }
            resolvedProfiles.append(builtInDefaultProfile)
            profiles = sortedProfiles(resolvedProfiles)
        } else {
            profiles = [builtInDefaultProfile]
            persist()
        }

        if let rawLastUsed = defaults.string(forKey: Self.lastUsedProfileDefaultsKey),
           let parsed = UUID(uuidString: rawLastUsed),
           profileDefinition(id: parsed) != nil {
            lastUsedProfileID = parsed
        } else {
            lastUsedProfileID = Self.builtInDefaultProfileID
            defaults.set(lastUsedProfileID.uuidString, forKey: Self.lastUsedProfileDefaultsKey)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesDefaultsKey)
    }

    private func sortedProfiles(_ profiles: [BrowserProfileDefinition]) -> [BrowserProfileDefinition] {
        profiles.sorted {
            if $0.isBuiltInDefault != $1.isBuiltInDefault {
                return $0.isBuiltInDefault && !$1.isBuiltInDefault
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

enum BrowserLinkOpenSettings {
    static let openTerminalLinksInCmuxBrowserKey = "browserOpenTerminalLinksInCmuxBrowser"
    static let defaultOpenTerminalLinksInCmuxBrowser: Bool = true

    static let openSidebarPullRequestLinksInCmuxBrowserKey = "browserOpenSidebarPullRequestLinksInCmuxBrowser"
    static let defaultOpenSidebarPullRequestLinksInCmuxBrowser: Bool = true

    static let interceptTerminalOpenCommandInCmuxBrowserKey = "browserInterceptTerminalOpenCommandInCmuxBrowser"
    static let defaultInterceptTerminalOpenCommandInCmuxBrowser: Bool = true

    static let browserHostWhitelistKey = "browserHostWhitelist"
    static let defaultBrowserHostWhitelist: String = ""
    static let browserExternalOpenPatternsKey = "browserExternalOpenPatterns"
    static let defaultBrowserExternalOpenPatterns: String = ""

    static func openTerminalLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) == nil {
            return defaultOpenTerminalLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
    }

    static func openSidebarPullRequestLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: openSidebarPullRequestLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPullRequestLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPullRequestLinksInCmuxBrowserKey)
    }

    static func interceptTerminalOpenCommandInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: interceptTerminalOpenCommandInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: interceptTerminalOpenCommandInCmuxBrowserKey)
        }

        // Migrate existing behavior for users who only had the link-click toggle.
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
        }

        return defaultInterceptTerminalOpenCommandInCmuxBrowser
    }

    static func initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: UserDefaults = .standard) -> Bool {
        interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults)
    }

    static func hostWhitelist(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserHostWhitelistKey) ?? defaultBrowserHostWhitelist
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func externalOpenPatterns(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserExternalOpenPatternsKey) ?? defaultBrowserExternalOpenPatterns
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func shouldOpenExternally(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        shouldOpenExternally(url.absoluteString, defaults: defaults)
    }

    static func shouldOpenExternally(_ rawURL: String, defaults: UserDefaults = .standard) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        for rawPattern in externalOpenPatterns(defaults: defaults) {
            guard let (isRegex, value) = parseExternalPattern(rawPattern) else { continue }
            if isRegex {
                guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { continue }
                let range = NSRange(target.startIndex..<target.endIndex, in: target)
                if regex.firstMatch(in: target, options: [], range: range) != nil {
                    return true
                }
            } else if target.range(of: value, options: [.caseInsensitive]) != nil {
                return true
            }
        }

        return false
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

    private static func parseExternalPattern(_ rawPattern: String) -> (isRegex: Bool, value: String)? {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("re:") {
            let regexPattern = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !regexPattern.isEmpty else { return nil }
            return (isRegex: true, value: regexPattern)
        }

        return (isRegex: false, value: trimmed)
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

func browserReadAccessURL(forLocalFileURL fileURL: URL, fileManager: FileManager = .default) -> URL? {
    guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { return nil }
    let path = fileURL.path
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
        return fileURL
    }

    let parent = fileURL.deletingLastPathComponent()
    guard !parent.path.isEmpty, parent.path.hasPrefix("/") else { return nil }
    return parent
}

@discardableResult
func browserLoadRequest(_ request: URLRequest, in webView: WKWebView) -> WKNavigation? {
    guard let url = request.url else { return nil }
    if url.isFileURL {
        guard let readAccessURL = browserReadAccessURL(forLocalFileURL: url) else { return nil }
        return webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }
    return webView.load(browserPreparedNavigationRequest(request))
}

private let browserEmbeddedNavigationSchemes: Set<String> = [
    "about",
    "applewebdata",
    "blob",
    "data",
    "file",
    "http",
    "https",
    "javascript",
]

func browserShouldOpenURLExternally(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
    return !browserEmbeddedNavigationSchemes.contains(scheme)
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

    nonisolated static func defaultHistoryFileURLForCurrentBundle() -> URL? {
        defaultHistoryFileURL()
    }

    nonisolated static func normalizedBrowserHistoryNamespaceForBundleIdentifier(_ bundleIdentifier: String) -> String {
        normalizedBrowserHistoryNamespace(bundleIdentifier: bundleIdentifier)
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
        case .google, .bing, .kagi, .startpage:
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

/// Observable state for browser find-in-page. Mirrors `TerminalSurface.SearchState`.
@MainActor
final class BrowserSearchState: ObservableObject {
    @Published var needle: String
    @Published var selected: UInt?
    @Published var total: UInt?

    init(needle: String = "") {
        self.needle = needle
    }
}

final class BrowserPortalAnchorView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class BrowserPanel: Panel, ObservableObject {
    private static let remoteLoopbackProxyAliasHost = "cmux-loopback.localtest.me"
    private static let remoteLoopbackHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
    ]

    /// Shared process pool for cookie sharing across all browser panels
    private static let sharedProcessPool = WKProcessPool()

    /// Popup windows owned by this panel (for lifecycle cleanup)
    private var popupControllers: [BrowserPopupWindowController] = []

    static let telemetryHookBootstrapScriptSource = """
    (() => {
      if (window.__cmuxHooksInstalled) return true;
      window.__cmuxHooksInstalled = true;

      window.__cmuxConsoleLog = window.__cmuxConsoleLog || [];
      const __pushConsole = (level, args) => {
        try {
          const text = Array.from(args || []).map((x) => {
            if (typeof x === 'string') return x;
            try { return JSON.stringify(x); } catch (_) { return String(x); }
          }).join(' ');
          window.__cmuxConsoleLog.push({ level, text, timestamp_ms: Date.now() });
          if (window.__cmuxConsoleLog.length > 512) {
            window.__cmuxConsoleLog.splice(0, window.__cmuxConsoleLog.length - 512);
          }
        } catch (_) {}
      };

      const methods = ['log', 'info', 'warn', 'error', 'debug'];
      for (const m of methods) {
        const orig = (window.console && window.console[m]) ? window.console[m].bind(window.console) : null;
        window.console[m] = function(...args) {
          __pushConsole(m, args);
          if (orig) return orig(...args);
        };
      }

      window.__cmuxErrorLog = window.__cmuxErrorLog || [];
      window.addEventListener('error', (ev) => {
        try {
          const message = String((ev && ev.message) || '');
          const source = String((ev && ev.filename) || '');
          const line = Number((ev && ev.lineno) || 0);
          const col = Number((ev && ev.colno) || 0);
          window.__cmuxErrorLog.push({ message, source, line, column: col, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });
      window.addEventListener('unhandledrejection', (ev) => {
        try {
          const reason = ev && ev.reason;
          const message = typeof reason === 'string' ? reason : (reason && reason.message ? String(reason.message) : String(reason));
          window.__cmuxErrorLog.push({ message, source: 'unhandledrejection', line: 0, column: 0, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });

      return true;
    })()
    """

    static let dialogTelemetryHookBootstrapScriptSource = """
    (() => {
      if (window.__cmuxDialogHooksInstalled) return true;
      window.__cmuxDialogHooksInstalled = true;

      window.__cmuxDialogQueue = window.__cmuxDialogQueue || [];
      window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
      const __pushDialog = (type, message, defaultText) => {
        window.__cmuxDialogQueue.push({
          type,
          message: String(message || ''),
          default_text: defaultText == null ? null : String(defaultText),
          timestamp_ms: Date.now()
        });
        if (window.__cmuxDialogQueue.length > 128) {
          window.__cmuxDialogQueue.splice(0, window.__cmuxDialogQueue.length - 128);
        }
      };

      window.alert = function(message) {
        __pushDialog('alert', message, null);
      };
      window.confirm = function(message) {
        __pushDialog('confirm', message, null);
        return !!window.__cmuxDialogDefaults.confirm;
      };
      window.prompt = function(message, defaultValue) {
        __pushDialog('prompt', message, defaultValue == null ? null : defaultValue);
        const v = window.__cmuxDialogDefaults.prompt;
        if (v === null || v === undefined) {
          return defaultValue == null ? '' : String(defaultValue);
        }
        return String(v);
      };

      return true;
    })()
    """

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

    @Published private(set) var profileID: UUID
    @Published private(set) var historyStore: BrowserHistoryStore

    /// The underlying web view
    private(set) var webView: WKWebView
    private var websiteDataStore: WKWebsiteDataStore

    /// Monotonic identity for the current WKWebView instance.
    /// Incremented whenever we replace the underlying WKWebView after a process crash.
    @Published private(set) var webViewInstanceID: UUID = UUID()

    /// Prevent the omnibar from auto-focusing for a short window after explicit programmatic focus.
    /// This avoids races where SwiftUI focus state steals first responder back from WebKit.
    private var suppressOmnibarAutofocusUntil: Date?

    /// Prevent forcing web-view focus when another UI path requested omnibar focus.
    /// Used to keep omnibar text-field focus from being immediately stolen by panel focus.
    private var suppressWebViewFocusUntil: Date?
    private var suppressWebViewFocusForAddressBar: Bool = false
    private var addressBarFocusRestoreGeneration: UInt64 = 0
    private let blankURLString = "about:blank"
    private static let addressBarFocusCaptureScript = """
    (() => {
      try {
        const syncState = (state) => {
          window.__cmuxAddressBarFocusState = state;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: state }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = state;
            }
          } catch (_) {}
        };

        const active = document.activeElement;
        if (!active) {
          syncState(null);
          return "cleared:none";
        }

        const tag = (active.tagName || "").toLowerCase();
        const type = (active.type || "").toLowerCase();
        const isEditable =
          !!active.isContentEditable ||
          tag === "textarea" ||
          (tag === "input" && type !== "hidden");
        if (!isEditable) {
          syncState(null);
          return "cleared:noneditable";
        }

        let id = active.getAttribute("data-cmux-addressbar-focus-id");
        if (!id) {
          id = "cmux-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
          active.setAttribute("data-cmux-addressbar-focus-id", id);
        }

        const state = { id, selectionStart: null, selectionEnd: null };
        if (typeof active.selectionStart === "number" && typeof active.selectionEnd === "number") {
          state.selectionStart = active.selectionStart;
          state.selectionEnd = active.selectionEnd;
        }
        syncState(state);
        return "captured:" + id;
      } catch (_) {
        return "error";
      }
    })();
    """
    private static let addressBarFocusTrackingBootstrapScript = """
    (() => {
      try {
        if (window.__cmuxAddressBarFocusTrackerInstalled) return true;
        window.__cmuxAddressBarFocusTrackerInstalled = true;

        const syncState = (state) => {
          window.__cmuxAddressBarFocusState = state;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: state }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = state;
            }
          } catch (_) {}
        };

        if (window.top === window && !window.__cmuxAddressBarFocusMessageBridgeInstalled) {
          window.__cmuxAddressBarFocusMessageBridgeInstalled = true;
          window.addEventListener("message", (ev) => {
            try {
              const data = ev ? ev.data : null;
              if (!data || !Object.prototype.hasOwnProperty.call(data, "cmuxAddressBarFocusState")) return;
              window.__cmuxAddressBarFocusState = data.cmuxAddressBarFocusState || null;
            } catch (_) {}
          }, true);
        }

        const isEditable = (el) => {
          if (!el) return false;
          const tag = (el.tagName || "").toLowerCase();
          const type = (el.type || "").toLowerCase();
          return !!el.isContentEditable || tag === "textarea" || (tag === "input" && type !== "hidden");
        };

        const ensureFocusId = (el) => {
          let id = el.getAttribute("data-cmux-addressbar-focus-id");
          if (!id) {
            id = "cmux-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
            el.setAttribute("data-cmux-addressbar-focus-id", id);
          }
          return id;
        };

        const snapshot = (el) => {
          if (!isEditable(el)) {
            syncState(null);
            return;
          }
          const state = {
            id: ensureFocusId(el),
            selectionStart: null,
            selectionEnd: null
          };
          if (typeof el.selectionStart === "number" && typeof el.selectionEnd === "number") {
            state.selectionStart = el.selectionStart;
            state.selectionEnd = el.selectionEnd;
          }
          syncState(state);
        };

        document.addEventListener("focusin", (ev) => {
          snapshot(ev && ev.target ? ev.target : document.activeElement);
        }, true);
        document.addEventListener("selectionchange", () => {
          snapshot(document.activeElement);
        }, true);
        document.addEventListener("input", () => {
          snapshot(document.activeElement);
        }, true);
        document.addEventListener("mousedown", (ev) => {
          const target = ev && ev.target ? ev.target : null;
          if (!isEditable(target)) {
            syncState(null);
          }
        }, true);
        window.addEventListener("beforeunload", () => {
          syncState(null);
        }, true);

        snapshot(document.activeElement);
        return true;
      } catch (_) {
        return false;
      }
    })();
    """
    private static let addressBarFocusRestoreScript = """
    (() => {
      try {
        const readState = () => {
          let state = window.__cmuxAddressBarFocusState;
          try {
            if ((!state || typeof state.id !== "string" || !state.id) &&
                window.top && window.top.__cmuxAddressBarFocusState) {
              state = window.top.__cmuxAddressBarFocusState;
            }
          } catch (_) {}
          return state;
        };

        const clearState = () => {
          window.__cmuxAddressBarFocusState = null;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: null }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = null;
            }
          } catch (_) {}
        };

        const state = readState();
        if (!state || typeof state.id !== "string" || !state.id) {
          return "no_state";
        }

        const selector = '[data-cmux-addressbar-focus-id="' + state.id + '"]';
        const findTarget = (doc) => {
          if (!doc) return null;
          const direct = doc.querySelector(selector);
          if (direct && direct.isConnected) return direct;
          const frames = doc.querySelectorAll("iframe,frame");
          for (let i = 0; i < frames.length; i += 1) {
            const frame = frames[i];
            try {
              const childDoc = frame.contentDocument;
              if (!childDoc) continue;
              const nested = findTarget(childDoc);
              if (nested) return nested;
            } catch (_) {}
          }
          return null;
        };

        const target = findTarget(document);
        if (!target) {
          clearState();
          return "missing_target";
        }

        try {
          target.focus({ preventScroll: true });
        } catch (_) {
          try { target.focus(); } catch (_) {}
        }

        let focused = false;
        try {
          focused =
            target === target.ownerDocument.activeElement ||
            (typeof target.matches === "function" && target.matches(":focus"));
        } catch (_) {}
        if (!focused) {
          return "not_focused";
        }

        if (
          typeof state.selectionStart === "number" &&
          typeof state.selectionEnd === "number" &&
          typeof target.setSelectionRange === "function"
        ) {
          try {
            target.setSelectionRange(state.selectionStart, state.selectionEnd);
          } catch (_) {}
        }
        clearState();
        return "restored";
      } catch (_) {
        return "error";
      }
    })();
    """

    /// Published URL being displayed
    @Published private(set) var currentURL: URL?

    /// Whether the browser panel should render its WKWebView in the content area.
    /// New browser tabs stay in an empty "new tab" state until first navigation.
    @Published private(set) var shouldRenderWebView: Bool = false

    /// True when the browser is showing the internal empty new-tab page (no WKWebView attached yet).
    var isShowingNewTabPage: Bool {
        !shouldRenderWebView
    }

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

    private var nativeCanGoBack: Bool = false
    private var nativeCanGoForward: Bool = false
    private var usesRestoredSessionHistory: Bool = false
    private var restoredBackHistoryStack: [URL] = []
    private var restoredForwardHistoryStack: [URL] = []
    private var restoredHistoryCurrentURL: URL?

    /// Published estimated progress (0.0 - 1.0)
    @Published private(set) var estimatedProgress: Double = 0.0

    /// Increment to request a UI-only flash highlight (e.g. from a keyboard shortcut).
    @Published private(set) var focusFlashToken: Int = 0

    /// Sticky omnibar-focus intent. This survives view mount timing races and is
    /// cleared only after BrowserPanelView acknowledges handling it.
    @Published private(set) var pendingAddressBarFocusRequestId: UUID?

    /// Semantic in-panel focus target used by split switching and transient overlays.
    private(set) var preferredFocusIntent: BrowserPanelFocusIntent = .webView

    /// Incremented whenever async browser find focus ownership changes.
    @Published private(set) var searchFocusRequestGeneration: UInt64 = 0

    /// Find-in-page state. Non-nil when the find bar is visible.
    @Published var searchState: BrowserSearchState? = nil {
        didSet {
            if let searchState {
                preferredFocusIntent = .findField
                NSLog("Find: browser search state created panel=%@", id.uuidString)
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }
                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
                        guard let self else { return }
                        NSLog("Find: browser needle updated panel=%@ needle=%@", self.id.uuidString, needle)
                        self.executeFindSearch(needle)
                    }
            } else if oldValue != nil {
                searchNeedleCancellable = nil
                if preferredFocusIntent == .findField {
                    preferredFocusIntent = .webView
                }
                invalidateSearchFocusRequests(reason: "searchStateCleared")
                NSLog("Find: browser search state cleared panel=%@", id.uuidString)
                executeFindClear()
            }
        }
    }
    private var searchNeedleCancellable: AnyCancellable?
    let portalAnchorView = BrowserPortalAnchorView(frame: .zero)
    private struct PortalHostLease {
        let hostId: ObjectIdentifier
        let paneId: UUID
        let inWindow: Bool
        let area: CGFloat
    }
    private struct PortalHostLock {
        let hostId: ObjectIdentifier
        let paneId: UUID
    }
    private enum DeveloperToolsPresentation {
        case unknown
        case attached
        case detached
    }
    private var activePortalHostLease: PortalHostLease?
    private var pendingDistinctPortalHostReplacementPaneId: UUID?
    private var lockedPortalHost: PortalHostLock?
    private var webViewCancellables = Set<AnyCancellable>()
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
    private var insecureHTTPAlertFactory: () -> NSAlert
    private var insecureHTTPAlertWindowProvider: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    // Persist user intent across WebKit detach/reattach churn (split/layout updates).
    @Published private(set) var preferredDeveloperToolsVisible: Bool = false
    private var preferredDeveloperToolsPresentation: DeveloperToolsPresentation = .unknown
    private var forceDeveloperToolsRefreshOnNextAttach: Bool = false
    private var developerToolsRestoreRetryWorkItem: DispatchWorkItem?
    private var developerToolsRestoreRetryAttempt: Int = 0
    private let developerToolsRestoreRetryDelay: TimeInterval = 0.05
    private let developerToolsRestoreRetryMaxAttempts: Int = 40
    private var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published private(set) var remoteWorkspaceStatus: BrowserRemoteWorkspaceStatus?
    private var usesRemoteWorkspaceProxy: Bool
    private struct PendingRemoteNavigation {
        let request: URLRequest
        let recordTypedNavigation: Bool
        let preserveRestoredSessionHistory: Bool
    }
    private var pendingRemoteNavigation: PendingRemoteNavigation?
    private let developerToolsDetachedOpenGracePeriod: TimeInterval = 0.35
    private var developerToolsDetachedOpenGraceDeadline: Date?
    private var developerToolsTransitionTargetVisible: Bool?
    private var pendingDeveloperToolsTransitionTargetVisible: Bool?
    private var developerToolsTransitionSettleWorkItem: DispatchWorkItem?
    private var developerToolsVisibilityLossCheckWorkItem: DispatchWorkItem?
    private let developerToolsTransitionSettleDelay: TimeInterval = 0.15
    private let developerToolsAttachedManualCloseDetectionDelay: TimeInterval = 0.35
    private var developerToolsLastAttachedHostAt: Date?
    private var developerToolsLastKnownVisibleAt: Date?
    private var detachedDeveloperToolsWindowCloseObserver: NSObjectProtocol?
    private var preferredAttachedDeveloperToolsWidth: CGFloat?
    private var preferredAttachedDeveloperToolsWidthFraction: CGFloat?
    private var browserThemeMode: BrowserThemeMode

    var displayTitle: String {
        if !pageTitle.isEmpty {
            return pageTitle
        }
        if let url = currentURL {
            return url.host ?? url.absoluteString
        }
        return String(localized: "browser.newTab", defaultValue: "New tab")
    }

    var profileDisplayName: String {
        BrowserProfileStore.shared.displayName(for: profileID)
    }

    var usesBuiltInDefaultProfile: Bool {
        profileID == BrowserProfileStore.shared.builtInDefaultProfileID
    }

    private static let portalHostAreaThreshold: CGFloat = 4
    private static let portalHostReplacementAreaGainRatio: CGFloat = 1.2

    private static func portalHostArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    private static func portalHostIsUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > portalHostAreaThreshold
    }

    func preparePortalHostReplacementForNextDistinctClaim(
        inPane paneId: PaneID,
        reason: String
    ) {
        pendingDistinctPortalHostReplacementPaneId = paneId.id
        if lockedPortalHost?.paneId == paneId.id {
            lockedPortalHost = nil
        }
#if DEBUG
        dlog(
            "browser.portal.host.rearm panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) pane=\(paneId.id.uuidString.prefix(5))"
        )
#endif
    }

    func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        inWindow: Bool,
        bounds: CGRect,
        reason: String
    ) -> Bool {
        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        if let current = activePortalHostLease {
            if let lock = lockedPortalHost,
               (lock.hostId != current.hostId || lock.paneId != current.paneId) {
                lockedPortalHost = nil
            }

            if current.hostId == hostId {
                activePortalHostLease = next
                return true
            }

            let currentUsable = Self.portalHostIsUsable(current)
            let nextUsable = Self.portalHostIsUsable(next)
            let isSamePaneReplacement = current.paneId == paneId.id
            let shouldForceDistinctReplacement =
                isSamePaneReplacement &&
                pendingDistinctPortalHostReplacementPaneId == paneId.id &&
                inWindow
            if shouldForceDistinctReplacement {
#if DEBUG
                dlog(
                    "browser.portal.host.claim panel=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) replacingArea=\(String(format: "%.1f", current.area)) " +
                    "forced=1"
                )
#endif
                activePortalHostLease = next
                pendingDistinctPortalHostReplacementPaneId = nil
                lockedPortalHost = PortalHostLock(hostId: hostId, paneId: paneId.id)
                return true
            }

            let lockBlocksSamePaneReplacement =
                isSamePaneReplacement &&
                currentUsable &&
                lockedPortalHost?.hostId == current.hostId &&
                lockedPortalHost?.paneId == current.paneId
            let shouldReplace =
                current.paneId != paneId.id ||
                !currentUsable ||
                (
                    !lockBlocksSamePaneReplacement &&
                    nextUsable &&
                    next.area > (current.area * Self.portalHostReplacementAreaGainRatio)
                )

            if shouldReplace {
                if lockedPortalHost?.hostId == current.hostId &&
                    lockedPortalHost?.paneId == current.paneId {
                    lockedPortalHost = nil
                }
#if DEBUG
                dlog(
                    "browser.portal.host.claim panel=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) replacingArea=\(String(format: "%.1f", current.area))"
                )
#endif
                activePortalHostLease = next
                return true
            }

#if DEBUG
            dlog(
                "browser.portal.host.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                "ownerHost=\(current.hostId) ownerPane=\(current.paneId.uuidString.prefix(5)) " +
                "ownerInWin=\(current.inWindow ? 1 : 0) ownerArea=\(String(format: "%.1f", current.area)) " +
                "locked=\(lockBlocksSamePaneReplacement ? 1 : 0)"
            )
#endif
            return false
        }

        activePortalHostLease = next
#if DEBUG
        dlog(
            "browser.portal.host.claim panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
            "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "replacingHost=nil"
        )
#endif
        return true
    }

    @discardableResult
    func releasePortalHostIfOwned(hostId: ObjectIdentifier, reason: String) -> Bool {
        guard let current = activePortalHostLease, current.hostId == hostId else { return false }
        activePortalHostLease = nil
        if lockedPortalHost?.hostId == hostId {
            lockedPortalHost = nil
        }
#if DEBUG
        dlog(
            "browser.portal.host.release panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "inWin=\(current.inWindow ? 1 : 0) area=\(String(format: "%.1f", current.area))"
        )
#endif
        return true
    }

    var displayIcon: String? {
        "globe"
    }

    var isDirty: Bool {
        false
    }

    private static func makeWebView(
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) -> CmuxWebView {
        let config = WKWebViewConfiguration()
        configureWebViewConfiguration(
            config,
            websiteDataStore: websiteDataStore ?? BrowserProfileStore.shared.websiteDataStore(for: profileID)
        )

        let webView = CmuxWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        // Match the empty-page background to the terminal theme so newly-created browsers
        // don't flash white before content loads.
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        // Always present as Safari.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        return webView
    }

    static func configureWebViewConfiguration(
        _ configuration: WKWebViewConfiguration,
        websiteDataStore: WKWebsiteDataStore,
        processPool: WKProcessPool = BrowserPanel.sharedProcessPool
    ) {
        configuration.processPool = processPool
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Ensure browser cookies/storage persist across navigations and launches.
        // This reduces repeated consent/bot-challenge flows on sites like Google.
        configuration.websiteDataStore = websiteDataStore

        // Enable developer extras (DevTools)
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Enable JavaScript
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Keep browser console/error/dialog telemetry active from document start on every navigation.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.telemetryHookBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        // Track the last editable focused element continuously so omnibar exit can
        // restore page input focus even if capture runs after first-responder handoff.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.addressBarFocusTrackingBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
    }

    private func bindWebView(_ webView: CmuxWebView) {
        webView.onContextMenuDownloadStateChanged = { [weak self] downloading in
            if downloading {
                self?.beginDownloadActivity()
            } else {
                self?.endDownloadActivity()
            }
        }
        webView.onContextMenuOpenLinkInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        configureNavigationDelegateCallbacks()
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = uiDelegate
        setupObservers(for: webView)
    }

    private func configureNavigationDelegateCallbacks() {
        guard let navigationDelegate else { return }
        let boundWebViewInstanceID = webViewInstanceID
        let boundHistoryStore = historyStore

        navigationDelegate.didFinish = { [weak self] webView in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                boundHistoryStore.recordVisit(url: webView.url, title: webView.title)
                self.refreshFavicon(from: webView)
                self.applyBrowserThemeModeIfNeeded()
                // Keep find-in-page open through load completion and refresh matches for the new DOM.
                self.restoreFindStateAfterNavigation(replaySearch: true)
            }
        }
        navigationDelegate.didFailNavigation = { [weak self] failedWebView, failedURL in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(failedWebView, instanceID: boundWebViewInstanceID) else { return }
                // Clear stale title/favicon from the previous page so the tab
                // shows the failed URL instead of the old page's branding.
                self.pageTitle = failedURL.isEmpty ? "" : failedURL
                self.faviconPNGData = nil
                self.lastFaviconURLString = nil
                // Keep find-in-page open and clear stale counters on failed loads.
                self.restoreFindStateAfterNavigation(replaySearch: false)
            }
        }
    }

    private func isCurrentWebView(_ candidate: WKWebView, instanceID: UUID? = nil) -> Bool {
        guard candidate === webView else { return false }
        guard let instanceID else { return true }
        return instanceID == webViewInstanceID
    }

    init(
        workspaceId: UUID,
        profileID: UUID? = nil,
        initialURL: URL? = nil,
        bypassInsecureHTTPHostOnce: String? = nil,
        proxyEndpoint: BrowserProxyEndpoint? = nil,
        isRemoteWorkspace: Bool = false,
        remoteWebsiteDataStoreIdentifier: UUID? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        let requestedProfileID = profileID ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        let resolvedProfileID = BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
        self.profileID = resolvedProfileID
        self.historyStore = BrowserProfileStore.shared.historyStore(for: resolvedProfileID)
        self.insecureHTTPBypassHostOnce = BrowserInsecureHTTPSettings.normalizeHost(bypassInsecureHTTPHostOnce ?? "")
        self.remoteProxyEndpoint = proxyEndpoint
        self.usesRemoteWorkspaceProxy = isRemoteWorkspace
        self.browserThemeMode = BrowserThemeSettings.mode()
        self.websiteDataStore = isRemoteWorkspace
            ? WKWebsiteDataStore(forIdentifier: remoteWebsiteDataStoreIdentifier ?? workspaceId)
            : BrowserProfileStore.shared.websiteDataStore(for: resolvedProfileID)

        let webView = Self.makeWebView(
            profileID: resolvedProfileID,
            websiteDataStore: websiteDataStore
        )
        self.webView = webView
        self.insecureHTTPAlertFactory = { NSAlert() }
        applyRemoteProxyConfigurationIfAvailable()
        BrowserProfileStore.shared.noteUsed(resolvedProfileID)

        // Set up navigation delegate
        let navDelegate = BrowserNavigationDelegate()
        navDelegate.openInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        navDelegate.shouldBlockInsecureHTTPNavigation = { [weak self] url in
            self?.shouldBlockInsecureHTTPNavigation(to: url) ?? false
        }
        navDelegate.handleBlockedInsecureHTTPNavigation = { [weak self] request, intent in
            self?.presentInsecureHTTPAlert(for: request, intent: intent, recordTypedNavigation: false)
        }
        navDelegate.didTerminateWebContentProcess = { [weak self] webView in
            self?.replaceWebViewAfterContentProcessTermination(for: webView)
        }
        // Set up download delegate for navigation-based downloads.
        // Downloads save to a temp file synchronously (no NSSavePanel during WebKit
        // callbacks), then show NSSavePanel after the download completes.
        let dlDelegate = BrowserDownloadDelegate()
        dlDelegate.onDownloadStarted = { [weak self] filename in
            guard let self else { return }
            self.beginDownloadActivity()
            NotificationCenter.default.post(
                name: .browserDownloadEventDidArrive,
                object: self,
                userInfo: [
                    "surfaceId": self.id,
                    "workspaceId": self.workspaceId,
                    "event": [
                        "type": "started",
                        "filename": filename
                    ]
                ]
            )
        }
        dlDelegate.onDownloadReadyToSave = { [weak self] in
            guard let self else { return }
            self.endDownloadActivity()
            NotificationCenter.default.post(
                name: .browserDownloadEventDidArrive,
                object: self,
                userInfo: [
                    "surfaceId": self.id,
                    "workspaceId": self.workspaceId,
                    "event": [
                        "type": "ready_to_save"
                    ]
                ]
            )
        }
        dlDelegate.onDownloadFailed = { [weak self] error in
            guard let self else { return }
            self.endDownloadActivity()
            NotificationCenter.default.post(
                name: .browserDownloadEventDidArrive,
                object: self,
                userInfo: [
                    "surfaceId": self.id,
                    "workspaceId": self.workspaceId,
                    "event": [
                        "type": "failed",
                        "error": error.localizedDescription
                    ]
                ]
            )
        }
        navDelegate.downloadDelegate = dlDelegate
        self.downloadDelegate = dlDelegate
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
        browserUIDelegate.openPopup = { [weak self] configuration, windowFeatures in
            self?.createFloatingPopup(configuration: configuration, windowFeatures: windowFeatures)
        }
        self.uiDelegate = browserUIDelegate

        bindWebView(webView)
        installDetachedDeveloperToolsWindowCloseObserver()
        applyBrowserThemeModeIfNeeded()
        insecureHTTPAlertWindowProvider = { [weak self] in
            self?.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }

        // Navigate to initial URL if provided
        if let url = initialURL {
            shouldRenderWebView = true
            navigate(to: url)
        }
    }

    func setRemoteProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        guard remoteProxyEndpoint != endpoint else { return }
        remoteProxyEndpoint = endpoint
        applyRemoteProxyConfigurationIfAvailable()
        resumePendingRemoteNavigationIfNeeded()
    }

    func setRemoteWorkspaceStatus(_ status: BrowserRemoteWorkspaceStatus?) {
        guard remoteWorkspaceStatus != status else { return }
        remoteWorkspaceStatus = status
    }

    private func applyRemoteProxyConfigurationIfAvailable() {
        guard #available(macOS 14.0, *) else { return }

        let store = webView.configuration.websiteDataStore
        guard let endpoint = remoteProxyEndpoint else {
            store.proxyConfigurations = []
            return
        }

        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              endpoint.port > 0 && endpoint.port <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            store.proxyConfigurations = []
            return
        }

        let nwEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let socks = ProxyConfiguration(socksv5Proxy: nwEndpoint)
        let connect = ProxyConfiguration(httpCONNECTProxy: nwEndpoint)
        store.proxyConfigurations = [socks, connect]
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

    func reattachToWorkspace(
        _ newWorkspaceId: UUID,
        isRemoteWorkspace: Bool,
        remoteWebsiteDataStoreIdentifier: UUID? = nil,
        proxyEndpoint: BrowserProxyEndpoint?,
        remoteStatus: BrowserRemoteWorkspaceStatus?
    ) {
        workspaceId = newWorkspaceId
        usesRemoteWorkspaceProxy = isRemoteWorkspace
        let targetStore = isRemoteWorkspace
            ? WKWebsiteDataStore(forIdentifier: remoteWebsiteDataStoreIdentifier ?? newWorkspaceId)
            : BrowserProfileStore.shared.websiteDataStore(for: profileID)
        let needsStoreSwap = webView.configuration.websiteDataStore !== targetStore
        websiteDataStore = targetStore
        remoteProxyEndpoint = proxyEndpoint
        remoteWorkspaceStatus = remoteStatus
        if needsStoreSwap {
            replaceWebViewPreservingState(
                from: webView,
                websiteDataStore: targetStore,
                reason: "workspace_reattach"
            )
        }
        applyRemoteProxyConfigurationIfAvailable()
        resumePendingRemoteNavigationIfNeeded()
    }

    @discardableResult
    func switchToProfile(_ requestedProfileID: UUID) -> Bool {
        let resolvedProfileID = BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
        guard resolvedProfileID != profileID else {
            BrowserProfileStore.shared.noteUsed(resolvedProfileID)
            return false
        }

        let previousWebView = webView
        let wasRenderable = shouldRenderWebView
        let restoreURL = previousWebView.url ?? currentURL
        let restoreURLString = restoreURL?.absoluteString
        let shouldRestoreURL = wasRenderable && restoreURLString != nil && restoreURLString != blankURLString
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar()
        let desiredZoom = max(minPageZoom, min(maxPageZoom, previousWebView.pageZoom))
        let restoreDeveloperTools = preferredDeveloperToolsVisible || isDeveloperToolsVisible()

        invalidateSearchFocusRequests(reason: "profileSwitch")
        searchState = nil

        _ = hideDeveloperTools()
        cancelDeveloperToolsRestoreRetry()

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        BrowserWindowPortalRegistry.detach(webView: previousWebView)
        previousWebView.stopLoading()
        previousWebView.navigationDelegate = nil
        previousWebView.uiDelegate = nil
        if let previousCmuxWebView = previousWebView as? CmuxWebView {
            previousCmuxWebView.onContextMenuDownloadStateChanged = nil
        }

        profileID = resolvedProfileID
        historyStore = BrowserProfileStore.shared.historyStore(for: resolvedProfileID)
        BrowserProfileStore.shared.noteUsed(resolvedProfileID)

        if !usesRemoteWorkspaceProxy {
            websiteDataStore = BrowserProfileStore.shared.websiteDataStore(for: resolvedProfileID)
        }

        let replacement = Self.makeWebView(
            profileID: resolvedProfileID,
            websiteDataStore: websiteDataStore
        )
        replacement.pageZoom = desiredZoom
        webViewInstanceID = UUID()
        webView = replacement
        currentURL = restoreURL
        shouldRenderWebView = wasRenderable

        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()

        if !history.backHistoryURLStrings.isEmpty || !history.forwardHistoryURLStrings.isEmpty {
            restoreSessionNavigationHistory(
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                currentURLString: historyCurrentURL
            )
        }

        if shouldRestoreURL, let restoreURL {
            navigateWithoutInsecureHTTPPrompt(
                to: restoreURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
        } else {
            refreshNavigationAvailability()
        }

        if restoreDeveloperTools {
            requestDeveloperToolsRefreshAfterNextAttach(reason: "profile_switch")
        }

        return true
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken &+= 1
    }

    func sessionNavigationHistorySnapshot() -> (
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String]
    ) {
        if usesRestoredSessionHistory {
            let back = restoredBackHistoryStack.compactMap { Self.serializableSessionHistoryURLString($0) }
            // `restoredForwardHistoryStack` stores nearest-forward entries at the end.
            let forward = restoredForwardHistoryStack.reversed().compactMap { Self.serializableSessionHistoryURLString($0) }
            return (back, forward)
        }

        let back = webView.backForwardList.backList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }
        let forward = webView.backForwardList.forwardList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }
        return (back, forward)
    }

    func restoreSessionNavigationHistory(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) {
        let restoredBack = Self.sanitizedSessionHistoryURLs(backHistoryURLStrings)
        let restoredForward = Self.sanitizedSessionHistoryURLs(forwardHistoryURLStrings)
        guard !restoredBack.isEmpty || !restoredForward.isEmpty else { return }

        usesRestoredSessionHistory = true
        restoredBackHistoryStack = restoredBack
        // Store nearest-forward entries at the end to make stack pop operations trivial.
        restoredForwardHistoryStack = Array(restoredForward.reversed())
        restoredHistoryCurrentURL = Self.sanitizedSessionHistoryURL(currentURLString)
        refreshNavigationAvailability()
    }

    private func setupObservers(for webView: WKWebView) {
        let observedWebViewInstanceID = webViewInstanceID

        // URL changes
        let urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.currentURL = Self.remoteProxyDisplayURL(for: webView.url)
            }
        }
        webViewObservers.append(urlObserver)

        // Title changes
        let titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                // Keep showing the last non-empty title while the new navigation is loading.
                // WebKit often clears title to nil/"" during reload/navigation, which causes
                // a distracting tab-title flash (e.g. to host/URL). Only accept non-empty titles.
                let trimmed = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.pageTitle = trimmed
            }
        }
        webViewObservers.append(titleObserver)

        // Loading state
        let loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.handleWebViewLoadingChanged(webView.isLoading)
            }
        }
        webViewObservers.append(loadingObserver)

        // Can go back
        let backObserver = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.nativeCanGoBack = webView.canGoBack
                self.refreshNavigationAvailability()
            }
        }
        webViewObservers.append(backObserver)

        // Can go forward
        let forwardObserver = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.nativeCanGoForward = webView.canGoForward
                self.refreshNavigationAvailability()
            }
        }
        webViewObservers.append(forwardObserver)

        // Progress
        let progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.estimatedProgress = webView.estimatedProgress
            }
        }
        webViewObservers.append(progressObserver)

        NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)
            .sink { [weak self] notification in
                guard let self else { return }
                self.webView.underPageBackgroundColor = GhosttyBackgroundTheme.color(from: notification)
            }
            .store(in: &webViewCancellables)
    }

    private func replaceWebViewAfterContentProcessTermination(for terminatedWebView: WKWebView) {
        replaceWebViewPreservingState(
            from: terminatedWebView,
            websiteDataStore: websiteDataStore,
            reason: "webcontent_process_terminated"
        )
    }

    private func replaceWebViewPreservingState(
        from oldWebView: WKWebView,
        websiteDataStore: WKWebsiteDataStore,
        reason: String
    ) {
        guard oldWebView === webView else { return }

        let wasRenderable = shouldRenderWebView
        let restoreURL = Self.remoteProxyDisplayURL(for: oldWebView.url) ?? currentURL
        let restoreURLString = restoreURL?.absoluteString
        let shouldRestoreURL = wasRenderable && restoreURLString != nil && restoreURLString != blankURLString
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar()
        let desiredZoom = max(minPageZoom, min(maxPageZoom, oldWebView.pageZoom))
        let restoreDevTools = preferredDeveloperToolsVisible

#if DEBUG
        dlog(
            "browser.webview.replace.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "renderable=\(wasRenderable ? 1 : 0) restoreURL=\(restoreURLString ?? "nil") " +
            "restoreHistoryBack=\(history.backHistoryURLStrings.count) " +
            "restoreHistoryForward=\(history.forwardHistoryURLStrings.count)"
        )
#endif

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        if let oldCmuxWebView = oldWebView as? CmuxWebView {
            oldCmuxWebView.onContextMenuDownloadStateChanged = nil
        }

        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        replacement.pageZoom = desiredZoom
        webViewInstanceID = UUID()
        webView = replacement
        shouldRenderWebView = wasRenderable

        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()

        if !history.backHistoryURLStrings.isEmpty || !history.forwardHistoryURLStrings.isEmpty {
            restoreSessionNavigationHistory(
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                currentURLString: historyCurrentURL
            )
        }

        if shouldRestoreURL, let restoreURL {
            navigateWithoutInsecureHTTPPrompt(
                to: restoreURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
        } else {
            refreshNavigationAvailability()
        }

        if restoreDevTools {
            requestDeveloperToolsRefreshAfterNextAttach(reason: reason)
        }

#if DEBUG
        dlog(
            "browser.webview.replace.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "instance=\(webViewInstanceID.uuidString.prefix(6)) " +
            "restoreURL=\(restoreURLString ?? "nil") shouldRestore=\(shouldRestoreURL ? 1 : 0)"
        )
#endif
    }

#if DEBUG
    func debugSimulateWebContentProcessTermination() {
        replaceWebViewAfterContentProcessTermination(for: webView)
    }
#endif

    // MARK: - Panel Protocol

    func focus() {
        if shouldSuppressWebViewFocus() {
            return
        }

        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }

        // If nothing meaningful is loaded yet, prefer letting the omnibar take focus.
        if !webView.isLoading {
            let urlString = Self.remoteProxyDisplayURL(for: webView.url)?.absoluteString ?? currentURL?.absoluteString
            if urlString == nil || urlString == "about:blank" {
                return
            }
        }

        if Self.responderChainContains(window.firstResponder, target: webView) {
            noteWebViewFocused()
            return
        }
        if window.makeFirstResponder(webView) {
            noteWebViewFocused()
        }
    }

    func unfocus() {
        invalidateSearchFocusRequests(reason: "panelUnfocus")
        guard let window = webView.window else { return }
        if Self.responderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        // Ensure we don't keep a hidden WKWebView (or its content view) as first responder while
        // bonsplit/SwiftUI reshuffles views during close.
        unfocus()

        // Snapshot first: popup close unregisters itself from popupControllers.
        let popupsToClose = popupControllers
        popupControllers.removeAll()

        // Close all owned popup windows before tearing down delegates
        for popup in popupsToClose {
            popup.closeAllChildPopups()
            popup.closePopup()
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        navigationDelegate = nil
        uiDelegate = nil
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        faviconTask?.cancel()
        faviconTask = nil
    }

    // MARK: - Popup window management

    func createFloatingPopup(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let controller = BrowserPopupWindowController(
            configuration: configuration,
            windowFeatures: windowFeatures,
            openerPanel: self
        )
        popupControllers.append(controller)
        return controller.webView
    }

    func removePopupController(_ controller: BrowserPopupWindowController) {
        popupControllers.removeAll { $0 === controller }
    }

    private func refreshFavicon(from webView: WKWebView) {
        faviconTask?.cancel()
        faviconTask = nil

        guard let pageURL = webView.url else { return }
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        faviconRefreshGeneration &+= 1
        let refreshGeneration = faviconRefreshGeneration
        let refreshWebViewInstanceID = webViewInstanceID

        faviconTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
#if DEBUG
            dlog(
                "browser.favicon.begin " +
                "panel=\(id.uuidString.prefix(5)) " +
                "page=\(pageURL.absoluteString)"
            )
#endif

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
            if let href = await self.evaluateJavaScriptString(
                js,
                in: webView,
                timeoutNanoseconds: 400_000_000
            ) {
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let u = URL(string: trimmed) {
                    discoveredURL = u
                }
            }
            guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            let fallbackURL = URL(string: "/favicon.ico", relativeTo: pageURL)
            let iconURL = discoveredURL ?? fallbackURL
            guard let iconURL else { return }
#if DEBUG
            dlog(
                "browser.favicon.iconURL " +
                "panel=\(id.uuidString.prefix(5)) " +
                "discovered=\(discoveredURL?.absoluteString ?? "<nil>") " +
                "fallback=\(fallbackURL?.absoluteString ?? "<nil>") " +
                "chosen=\(iconURL.absoluteString)"
            )
#endif

            // Avoid repeated fetches.
            let iconURLString = iconURL.absoluteString
            if iconURLString == lastFaviconURLString, faviconPNGData != nil {
#if DEBUG
                dlog(
                    "browser.favicon.skipCached " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "icon=\(iconURLString)"
                )
#endif
                return
            }
            lastFaviconURLString = iconURLString

            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 2.0
            req.cachePolicy = .returnCacheDataElseLoad
            req.setValue(BrowserUserAgentSettings.safariUserAgent, forHTTPHeaderField: "User-Agent")
            let effectiveRequest = remoteProxyPreparedRequest(from: req, logScope: "faviconRewrite")

            let data: Data
            let response: URLResponse
            do {
                let remoteSession = remoteProxyURLSession()
                defer { remoteSession?.finishTasksAndInvalidate() }
                if let remoteSession {
#if DEBUG
                    dlog(
                        "browser.favicon.fetch " +
                        "panel=\(id.uuidString.prefix(5)) " +
                        "via=proxy " +
                        "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                    )
#endif
                    (data, response) = try await remoteSession.data(for: effectiveRequest)
                } else {
#if DEBUG
                    dlog(
                        "browser.favicon.fetch " +
                        "panel=\(id.uuidString.prefix(5)) " +
                        "via=direct " +
                        "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                    )
#endif
                    (data, response) = try await URLSession.shared.data(for: effectiveRequest)
                }
            } catch {
#if DEBUG
                dlog(
                    "browser.favicon.fetchError " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "error=\(String(describing: error))"
                )
#endif
                return
            }
            guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
#if DEBUG
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog(
                    "browser.favicon.badResponse " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "status=\(status)"
                )
#endif
                return
            }
#if DEBUG
            dlog(
                "browser.favicon.response " +
                "panel=\(id.uuidString.prefix(5)) " +
                "status=\(http.statusCode) " +
                "bytes=\(data.count)"
            )
#endif

            // Use >= 2x the rendered point size so we don't upscale (blurry) on Retina.
            guard let png = Self.makeFaviconPNGData(from: data, targetPx: 32) else {
#if DEBUG
                dlog(
                    "browser.favicon.decodeFailed " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "bytes=\(data.count)"
                )
#endif
                return
            }
            // Only update if we got a real icon; keep the old one otherwise to avoid flashes.
            faviconPNGData = png
#if DEBUG
            dlog(
                "browser.favicon.ready " +
                "panel=\(id.uuidString.prefix(5)) " +
                "pngBytes=\(png.count)"
            )
#endif
        }
    }

    private func isCurrentFaviconRefresh(generation: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        return generation == faviconRefreshGeneration
    }

    @MainActor
    private func evaluateJavaScriptString(
        _ script: String,
        in webView: WKWebView,
        timeoutNanoseconds: UInt64
    ) async -> String? {
        await withCheckedContinuation { continuation in
            var hasResumed = false

            func resume(_ value: String?) {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: value)
            }

            webView.evaluateJavaScript(script) { result, _ in
                let value = result as? String
                Task { @MainActor in
                    resume(value)
                }
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                resume(nil)
            }
        }
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
            // Clear the previous page's favicon so it never persists across navigations.
            // The loading spinner covers this gap; didFinish will fetch the new favicon.
            faviconPNGData = nil
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

    private func navigateWithoutInsecureHTTPPrompt(
        to url: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false
    ) {
        let request = URLRequest(url: url)
        navigateWithoutInsecureHTTPPrompt(
            request: request,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory
        )
    }

    private func navigateWithoutInsecureHTTPPrompt(
        request: URLRequest,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false
    ) {
        guard let url = request.url else { return }
        if usesRemoteWorkspaceProxy, remoteProxyEndpoint == nil {
            pendingRemoteNavigation = PendingRemoteNavigation(
                request: request,
                recordTypedNavigation: recordTypedNavigation,
                preserveRestoredSessionHistory: preserveRestoredSessionHistory
            )
            shouldRenderWebView = true
            currentURL = Self.remoteProxyDisplayURL(for: url) ?? url
            navigationDelegate?.lastAttemptedURL = url
            return
        }
        performNavigation(
            request: request,
            originalURL: url,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory
        )
    }

    private func resumePendingRemoteNavigationIfNeeded() {
        guard remoteProxyEndpoint != nil,
              let pendingRemoteNavigation else {
            return
        }
        self.pendingRemoteNavigation = nil
        guard let originalURL = pendingRemoteNavigation.request.url else { return }
        performNavigation(
            request: pendingRemoteNavigation.request,
            originalURL: originalURL,
            recordTypedNavigation: pendingRemoteNavigation.recordTypedNavigation,
            preserveRestoredSessionHistory: pendingRemoteNavigation.preserveRestoredSessionHistory
        )
    }

    private func performNavigation(
        request: URLRequest,
        originalURL: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool
    ) {
        if !preserveRestoredSessionHistory {
            abandonRestoredSessionHistoryIfNeeded()
        }
        let effectiveRequest = remoteProxyPreparedRequest(from: request, logScope: "rewrite")
        // Some installs can end up with a legacy Chrome UA override; keep this pinned.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        shouldRenderWebView = true
        if recordTypedNavigation {
            historyStore.recordTypedNavigation(url: originalURL)
        }
        navigationDelegate?.lastAttemptedURL = originalURL
        browserLoadRequest(effectiveRequest, in: webView)
    }

    private func remoteProxyPreparedRequest(from request: URLRequest, logScope: String) -> URLRequest {
        guard remoteProxyEndpoint != nil else { return request }
        guard let url = request.url else { return request }
        guard let rewrittenURL = Self.remoteProxyLoopbackAliasURL(for: url) else { return request }

        var rewrittenRequest = request
        rewrittenRequest.url = rewrittenURL
#if DEBUG
        dlog(
            "browser.remoteProxy.\(logScope) " +
            "panel=\(id.uuidString.prefix(5)) " +
            "from=\(url.absoluteString) " +
            "to=\(rewrittenURL.absoluteString)"
        )
#endif
        return rewrittenRequest
    }

    private func remoteProxyURLSession() -> URLSession? {
        guard let endpoint = remoteProxyEndpoint else { return nil }
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, endpoint.port > 0, endpoint.port <= 65535 else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 2.0
        configuration.timeoutIntervalForResource = 4.0
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: endpoint.port,
        ]
        return URLSession(configuration: configuration)
    }

    private static func remoteProxyDisplayURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return url }
        guard host == BrowserInsecureHTTPSettings.normalizeHost(remoteLoopbackProxyAliasHost) else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "localhost"
        return components?.url ?? url
    }

    private static func remoteProxyLoopbackAliasURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return nil }
        guard remoteLoopbackHosts.contains(host) else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = remoteLoopbackProxyAliasHost
        return components?.url
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

        let alert = insecureHTTPAlertFactory()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
        alert.informativeText = String(localized: "browser.error.insecure.message", defaultValue: "\(host) uses plain HTTP, so traffic can be read or modified on the network.\n\nOpen this URL in your default browser, or proceed in cmux.")
        alert.addButton(withTitle: String(localized: "browser.openInDefaultBrowser", defaultValue: "Open in Default Browser"))
        alert.addButton(withTitle: String(localized: "browser.proceedInCmux", defaultValue: "Proceed in cmux"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "browser.alwaysAllowHost", defaultValue: "Always allow this host in cmux")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self, weak alert] response in
            self?.handleInsecureHTTPAlertResponse(
                response,
                alert: alert,
                host: host,
                request: request,
                url: url,
                intent: intent,
                recordTypedNavigation: recordTypedNavigation
            )
        }

        if let alertWindow = insecureHTTPAlertWindowProvider() {
            alert.beginSheetModal(for: alertWindow, completionHandler: handleResponse)
            return
        }

        handleResponse(alert.runModal())
    }

    private func handleInsecureHTTPAlertResponse(
        _ response: NSApplication.ModalResponse,
        alert: NSAlert?,
        host: String,
        request: URLRequest,
        url: URL,
        intent: BrowserInsecureHTTPNavigationIntent,
        recordTypedNavigation: Bool
    ) {
        if browserShouldPersistInsecureHTTPAllowlistSelection(
            response: response,
            suppressionEnabled: alert?.suppressionButton?.state == .on
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
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
        if let detachedDeveloperToolsWindowCloseObserver {
            NotificationCenter.default.removeObserver(detachedDeveloperToolsWindowCloseObserver)
        }
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        let webView = webView
        Task { @MainActor in
            BrowserWindowPortalRegistry.detach(webView: webView)
        }
    }
}

extension BrowserPanel {
    private var needsWorkspaceContextReset: Bool {
        shouldRenderWebView ||
        currentURL != nil ||
        !pageTitle.isEmpty ||
        faviconPNGData != nil ||
        searchState != nil ||
        nativeCanGoBack ||
        nativeCanGoForward ||
        restoredHistoryCurrentURL != nil ||
        !restoredBackHistoryStack.isEmpty ||
        !restoredForwardHistoryStack.isEmpty ||
        estimatedProgress > 0 ||
        isLoading ||
        isDownloading ||
        activeDownloadCount != 0 ||
        preferredDeveloperToolsVisible ||
        webView.superview != nil
    }

    func resetForWorkspaceContextChange(reason: String) {
        guard needsWorkspaceContextReset else {
#if DEBUG
            dlog(
                "browser.contextReset.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0)"
            )
#endif
            return
        }

#if DEBUG
        dlog(
            "browser.contextReset.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0) " +
            "url=\(preferredURLStringForOmnibar() ?? "nil")"
        )
#endif

        _ = hideDeveloperTools()
        cancelDeveloperToolsRestoreRetry()
        preferredDeveloperToolsVisible = false
        preferredDeveloperToolsPresentation = .unknown
        forceDeveloperToolsRefreshOnNextAttach = false
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsRestoreRetryAttempt = 0
        preferredAttachedDeveloperToolsWidth = nil
        preferredAttachedDeveloperToolsWidthFraction = nil

        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        activeDownloadCount = 0
        isDownloading = false
        isLoading = false
        estimatedProgress = 0
        nativeCanGoBack = false
        nativeCanGoForward = false
        navigationDelegate?.lastAttemptedURL = nil
        abandonRestoredSessionHistoryIfNeeded()

        pendingAddressBarFocusRequestId = nil
        preferredFocusIntent = .addressBar
        suppressOmnibarAutofocusUntil = nil
        suppressWebViewFocusUntil = nil
        endSuppressWebViewFocusForAddressBar()
        invalidateAddressBarPageFocusRestoreAttempts()
        invalidateSearchFocusRequests(reason: "contextReset")
        searchState = nil

        pageTitle = ""
        currentURL = nil
        faviconPNGData = nil
        lastFaviconURLString = nil
        activePortalHostLease = nil
        pendingDistinctPortalHostReplacementPaneId = nil
        lockedPortalHost = nil

        let oldWebView = webView
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        if let oldCmuxWebView = oldWebView as? CmuxWebView {
            oldCmuxWebView.onContextMenuDownloadStateChanged = nil
        }

        let replacement = Self.makeWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        webViewInstanceID = UUID()
        webView = replacement
        shouldRenderWebView = false
        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()
        refreshNavigationAvailability()

#if DEBUG
        dlog(
            "browser.contextReset.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) instance=\(webViewInstanceID.uuidString.prefix(6))"
        )
#endif
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
        if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
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
        if usesRestoredSessionHistory {
            guard let targetURL = restoredBackHistoryStack.popLast() else {
                refreshNavigationAvailability()
                return
            }
            if let current = resolvedCurrentSessionHistoryURL() {
                restoredForwardHistoryStack.append(current)
            }
            restoredHistoryCurrentURL = targetURL
            refreshNavigationAvailability()
            navigateWithoutInsecureHTTPPrompt(
                to: targetURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
            return
        }

        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        if usesRestoredSessionHistory {
            guard let targetURL = restoredForwardHistoryStack.popLast() else {
                refreshNavigationAvailability()
                return
            }
            if let current = resolvedCurrentSessionHistoryURL() {
                restoredBackHistoryStack.append(current)
            }
            restoredHistoryCurrentURL = targetURL
            refreshNavigationAvailability()
            navigateWithoutInsecureHTTPPrompt(
                to: targetURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
            return
        }

        webView.goForward()
    }

    /// Open a link in a new browser surface in the same pane
    func openLinkInNewTab(url: URL, bypassInsecureHTTPHostOnce: String? = nil) {
#if DEBUG
        dlog(
            "browser.newTab.open.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) url=\(url.absoluteString) " +
            "bypass=\(bypassInsecureHTTPHostOnce ?? "nil")"
        )
#endif
        guard let app = AppDelegate.shared else {
#if DEBUG
            dlog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=missingAppDelegate")
#endif
            return
        }
        guard let workspace = app.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace else {
#if DEBUG
            dlog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=workspaceMissing")
#endif
            return
        }
        guard let paneId = workspace.paneId(forPanelId: id) else {
#if DEBUG
            dlog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=paneMissing")
#endif
            return
        }
        workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            preferredProfileID: profileID,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
#if DEBUG
        dlog(
            "browser.newTab.open.done panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5))"
        )
#endif
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

    private static func windowContainsInspectorViews(_ root: NSView) -> Bool {
        if String(describing: type(of: root)).contains("WKInspector") {
            return true
        }
        for subview in root.subviews where windowContainsInspectorViews(subview) {
            return true
        }
        return false
    }

    private static func isDetachedInspectorWindow(_ window: NSWindow) -> Bool {
        guard window.title.hasPrefix("Web Inspector") else { return false }
        guard let contentView = window.contentView else { return false }
        return windowContainsInspectorViews(contentView)
    }

    private func detachedDeveloperToolsWindows() -> [NSWindow] {
        let mainWindow = webView.window
        return NSApp.windows.filter { candidate in
            if let mainWindow, candidate === mainWindow {
                return false
            }
            return Self.isDetachedInspectorWindow(candidate)
        }
    }

    private func hasAttachedDeveloperToolsLayout() -> Bool {
        guard let container = webView.superview else { return false }
        return Self.visibleDescendants(in: container)
            .contains { Self.isVisibleSideDockInspectorCandidate($0) && Self.isInspectorView($0) }
    }

    private func setPreferredDeveloperToolsPresentation(_ next: DeveloperToolsPresentation) {
        guard preferredDeveloperToolsPresentation != next else { return }
        preferredDeveloperToolsPresentation = next
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func syncDeveloperToolsPresentationPreferenceFromUI() {
        if !detachedDeveloperToolsWindows().isEmpty {
            setPreferredDeveloperToolsPresentation(.detached)
        } else if hasAttachedDeveloperToolsLayout() {
            setPreferredDeveloperToolsPresentation(.attached)
            developerToolsDetachedOpenGraceDeadline = nil
        }
    }

    private func installDetachedDeveloperToolsWindowCloseObserver() {
        guard detachedDeveloperToolsWindowCloseObserver == nil else { return }
        detachedDeveloperToolsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow else { return }
            let isDetachedInspectorWindow = MainActor.assumeIsolated {
                Self.isDetachedInspectorWindow(window)
            }
            guard isDetachedInspectorWindow else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.preferredDeveloperToolsPresentation == .detached else { return }
                guard self.preferredDeveloperToolsVisible else { return }
                guard !self.isDeveloperToolsVisible() else { return }
                self.developerToolsDetachedOpenGraceDeadline = nil
                self.preferredDeveloperToolsVisible = false
                self.cancelDeveloperToolsRestoreRetry()
#if DEBUG
                dlog(
                    "browser.devtools detachedClose.manual panel=\(self.id.uuidString.prefix(5)) " +
                    "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
                )
#endif
            }
        }
    }

    private func shouldDismissDetachedDeveloperToolsWindows() -> Bool {
        preferredDeveloperToolsPresentation == .attached
    }

    private func dismissDetachedDeveloperToolsWindowsIfNeeded() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible(),
              let mainWindow = webView.window else { return }
        for window in NSApp.windows where window !== mainWindow && Self.isDetachedInspectorWindow(window) {
#if DEBUG
            dlog(
                "browser.devtools strayWindow.close panel=\(id.uuidString.prefix(5)) " +
                "title=\(window.title) frame=\(NSStringFromRect(window.frame))"
            )
#endif
            window.close()
        }
    }

    private func scheduleDetachedDeveloperToolsWindowDismissal() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        for delay in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.dismissDetachedDeveloperToolsWindowsIfNeeded()
            }
        }
    }

    private func prepareDeveloperToolsForRevealIfNeeded(_ inspector: NSObject) {
        guard preferredDeveloperToolsPresentation == .unknown else { return }
        let attachSelector = NSSelectorFromString("attach")
        guard inspector.responds(to: attachSelector) else { return }
        inspector.cmuxCallVoid(selector: attachSelector)
    }

    @discardableResult
    private func revealDeveloperTools(_ inspector: NSObject) -> Bool {
        let isVisibleSelector = NSSelectorFromString("isVisible")
        if inspector.cmuxCallBool(selector: isVisibleSelector) ?? false {
            developerToolsDetachedOpenGraceDeadline = nil
            developerToolsLastKnownVisibleAt = Date()
            return true
        }

        prepareDeveloperToolsForRevealIfNeeded(inspector)

        let showSelector = NSSelectorFromString("show")
        guard inspector.responds(to: showSelector) else { return false }
        inspector.cmuxCallVoid(selector: showSelector)
        let visibleAfterShow = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        if visibleAfterShow {
            developerToolsLastKnownVisibleAt = Date()
        }
        if preferredDeveloperToolsPresentation == .detached {
            developerToolsDetachedOpenGraceDeadline = visibleAfterShow
                ? nil
                : Date().addingTimeInterval(developerToolsDetachedOpenGracePeriod)
        } else {
            developerToolsDetachedOpenGraceDeadline = nil
        }
        return visibleAfterShow
    }

    @discardableResult
    private func concealDeveloperTools(_ inspector: NSObject) -> Bool {
        let isVisibleSelector = NSSelectorFromString("isVisible")
        guard inspector.cmuxCallBool(selector: isVisibleSelector) ?? false else { return true }

        var invokedSelector = false
        for rawSelector in ["hide", "close"] {
            let selector = NSSelectorFromString(rawSelector)
            guard inspector.responds(to: selector) else { continue }
            invokedSelector = true
            inspector.cmuxCallVoid(selector: selector)
            if !(inspector.cmuxCallBool(selector: isVisibleSelector) ?? false) {
                return true
            }
        }

        guard invokedSelector else { return false }
        return !(inspector.cmuxCallBool(selector: isVisibleSelector) ?? false)
    }

    private var isDeveloperToolsTransitionInFlight: Bool {
        developerToolsTransitionSettleWorkItem != nil
    }

    private func effectiveDeveloperToolsVisibilityIntent() -> Bool {
        if let pendingDeveloperToolsTransitionTargetVisible {
            return pendingDeveloperToolsTransitionTargetVisible
        }
        if let developerToolsTransitionTargetVisible {
            return developerToolsTransitionTargetVisible
        }
        return isDeveloperToolsVisible()
    }

    private func scheduleDeveloperToolsTransitionSettle(source: String) {
        developerToolsTransitionSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.developerToolsTransitionSettleWorkItem = nil
            self?.finishDeveloperToolsTransition(source: source)
        }
        developerToolsTransitionSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + developerToolsTransitionSettleDelay, execute: workItem)
    }

    private func finishDeveloperToolsTransition(source: String) {
        let pendingTargetVisible = pendingDeveloperToolsTransitionTargetVisible
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil

        guard let pendingTargetVisible else { return }
        guard pendingTargetVisible != isDeveloperToolsVisible() else { return }
        _ = performDeveloperToolsVisibilityTransition(to: pendingTargetVisible, source: "\(source).queued")
    }

    @discardableResult
    private func enqueueDeveloperToolsVisibilityTransition(
        to targetVisible: Bool,
        source: String
    ) -> Bool {
        if isDeveloperToolsTransitionInFlight {
            pendingDeveloperToolsTransitionTargetVisible = targetVisible
            preferredDeveloperToolsVisible = targetVisible
            if !targetVisible {
                developerToolsDetachedOpenGraceDeadline = nil
                forceDeveloperToolsRefreshOnNextAttach = false
                cancelDeveloperToolsRestoreRetry()
            }
#if DEBUG
            dlog(
                "browser.devtools transition.queue panel=\(id.uuidString.prefix(5)) " +
                "source=\(source) target=\(targetVisible ? 1 : 0) \(debugDeveloperToolsStateSummary())"
            )
#endif
            return true
        }

        return performDeveloperToolsVisibilityTransition(to: targetVisible, source: source)
    }

    @discardableResult
    private func performDeveloperToolsVisibilityTransition(
        to targetVisible: Bool,
        source: String
    ) -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let visible = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        preferredDeveloperToolsVisible = targetVisible
        developerToolsTransitionTargetVisible = targetVisible

        if targetVisible {
            if !visible {
                _ = revealDeveloperTools(inspector)
            } else {
                developerToolsDetachedOpenGraceDeadline = nil
            }
        } else {
            if visible {
                syncDeveloperToolsPresentationPreferenceFromUI()
                guard concealDeveloperTools(inspector) else {
                    developerToolsTransitionTargetVisible = nil
                    return false
                }
            }
            developerToolsDetachedOpenGraceDeadline = nil
        }

        if targetVisible {
            let visibleAfterTransition = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
            if visibleAfterTransition {
                syncDeveloperToolsPresentationPreferenceFromUI()
                cancelDeveloperToolsRestoreRetry()
                scheduleDetachedDeveloperToolsWindowDismissal()
            } else {
                developerToolsRestoreRetryAttempt = 0
                scheduleDeveloperToolsRestoreRetry()
            }
        } else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
        }

        if visible != targetVisible {
            scheduleDeveloperToolsTransitionSettle(source: source)
        } else {
            developerToolsTransitionTargetVisible = nil
        }

        return true
    }

    @discardableResult
    func toggleDeveloperTools() -> Bool {
#if DEBUG
        dlog(
            "browser.devtools toggle.begin panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        let targetVisible = !effectiveDeveloperToolsVisibilityIntent()
        let handled = enqueueDeveloperToolsVisibilityTransition(to: targetVisible, source: "toggle")
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
        return handled
    }

    @discardableResult
    func showDeveloperTools() -> Bool {
        return enqueueDeveloperToolsVisibilityTransition(to: true, source: "show")
    }

    @discardableResult
    func showDeveloperToolsConsole() -> Bool {
        guard showDeveloperTools() else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return true }
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
        if isDeveloperToolsTransitionInFlight {
            let targetVisible = pendingDeveloperToolsTransitionTargetVisible ?? developerToolsTransitionTargetVisible ?? visible
            preferredDeveloperToolsVisible = targetVisible
            if targetVisible, visible {
                developerToolsDetachedOpenGraceDeadline = nil
                syncDeveloperToolsPresentationPreferenceFromUI()
                cancelDeveloperToolsRestoreRetry()
            } else if !targetVisible {
                developerToolsDetachedOpenGraceDeadline = nil
                forceDeveloperToolsRefreshOnNextAttach = false
                cancelDeveloperToolsRestoreRetry()
            }
            return
        }
        if visible {
            developerToolsDetachedOpenGraceDeadline = nil
            syncDeveloperToolsPresentationPreferenceFromUI()
            preferredDeveloperToolsVisible = true
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
            return
        }
        if preserveVisibleIntent && preferredDeveloperToolsVisible {
            return
        }
        preferredDeveloperToolsVisible = false
        developerToolsLastKnownVisibleAt = nil
        cancelDeveloperToolsRestoreRetry()
    }

    func noteDeveloperToolsHostAttached() {
        cancelPendingDeveloperToolsVisibilityLossCheck()
        developerToolsLastAttachedHostAt = Date()
        if isDeveloperToolsVisible() {
            developerToolsLastKnownVisibleAt = Date()
        }
    }

    func scheduleDeveloperToolsVisibilityLossCheck() {
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        let attachedAge = developerToolsLastAttachedHostAt.map { Date().timeIntervalSince($0) } ?? 0
        let delay = max(
            developerToolsTransitionSettleDelay,
            developerToolsAttachedManualCloseDetectionDelay - attachedAge
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.developerToolsVisibilityLossCheckWorkItem = nil
            _ = self.consumeAttachedDeveloperToolsManualCloseIfNeeded()
        }
        developerToolsVisibilityLossCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
    }

    func cancelPendingDeveloperToolsVisibilityLossCheck() {
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
    }

    @discardableResult
    func consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: NSObject? = nil) -> Bool {
        guard preferredDeveloperToolsVisible else { return false }
        guard preferredDeveloperToolsPresentation != .detached else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return false }
        guard webView.superview != nil, webView.window != nil else { return false }
        guard let developerToolsLastAttachedHostAt else { return false }
        guard Date().timeIntervalSince(developerToolsLastAttachedHostAt) >= developerToolsAttachedManualCloseDetectionDelay else {
            return false
        }
        guard developerToolsLastKnownVisibleAt != nil else { return false }
        guard let inspector = inspector ?? webView.cmuxInspectorObject() else { return false }
        guard let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) else { return false }
        guard !visible else {
            developerToolsLastKnownVisibleAt = Date()
            return false
        }

        preferredDeveloperToolsVisible = false
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        cancelDeveloperToolsRestoreRetry()
#if DEBUG
        dlog(
            "browser.devtools attachedClose.consume panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return true
    }

    /// Called after WKWebView reattaches to keep inspector stable across split/layout churn.
    func restoreDeveloperToolsAfterAttachIfNeeded() {
        guard preferredDeveloperToolsVisible else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
            return
        }
        guard !isDeveloperToolsTransitionInFlight else { return }
        guard let inspector = webView.cmuxInspectorObject() else {
            scheduleDeveloperToolsRestoreRetry()
            return
        }

        let shouldForceRefresh = forceDeveloperToolsRefreshOnNextAttach
        forceDeveloperToolsRefreshOnNextAttach = false

        let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visible {
            developerToolsDetachedOpenGraceDeadline = nil
            syncDeveloperToolsPresentationPreferenceFromUI()
            developerToolsLastKnownVisibleAt = Date()
            #if DEBUG
            if shouldForceRefresh {
                dlog("browser.devtools refresh.consumeVisible panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
            }
            #endif
            cancelDeveloperToolsRestoreRetry()
            return
        }

        let detachedOpenStillSettling = developerToolsDetachedOpenGraceDeadline.map { $0 > Date() } ?? false
        if preferredDeveloperToolsPresentation == .detached && !detachedOpenStillSettling {
            preferredDeveloperToolsVisible = false
            developerToolsDetachedOpenGraceDeadline = nil
            cancelDeveloperToolsRestoreRetry()
#if DEBUG
            dlog(
                "browser.devtools detachedClose.consume panel=\(id.uuidString.prefix(5)) " +
                "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
            )
#endif
            return
        }

        if consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: inspector) {
            return
        }

        #if DEBUG
        if shouldForceRefresh {
            dlog("browser.devtools refresh.forceShowWhenHidden panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
        }
        #endif
        // WebKit inspector show can trigger transient first-responder churn while
        // panel attachment is still stabilizing. Keep this auto-restore path from
        // mutating first responder so AppKit doesn't walk tearing-down responder chains.
        cmuxWithWindowFirstResponderBypass {
            _ = revealDeveloperTools(inspector)
        }
        preferredDeveloperToolsVisible = true
        let visibleAfterShow = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visibleAfterShow {
            syncDeveloperToolsPresentationPreferenceFromUI()
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
            scheduleDetachedDeveloperToolsWindowDismissal()
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
        return enqueueDeveloperToolsVisibilityTransition(to: false, source: "hide")
    }

    /// During split/layout transitions SwiftUI can briefly mark the browser surface hidden
    /// while its container is off-window. Avoid detaching in that transient phase if
    /// DevTools is intended to remain open, because detach/reattach can blank inspector content.
    func shouldPreserveWebViewAttachmentDuringTransientHide() -> Bool {
        preferredDeveloperToolsVisible && !hasSideDockedDeveloperToolsLayout()
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

    func shouldPreserveDeveloperToolsIntentWhileDetached() -> Bool {
        preferredDeveloperToolsVisible &&
            (
                forceDeveloperToolsRefreshOnNextAttach ||
                developerToolsRestoreRetryWorkItem != nil ||
                webView.superview == nil ||
                webView.window == nil
            )
    }

    func shouldUseLocalInlineDeveloperToolsHosting() -> Bool {
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible() else { return false }
        if preferredDeveloperToolsPresentation == .detached {
            return false
        }
        return detachedDeveloperToolsWindows().isEmpty
    }

    func recordPreferredAttachedDeveloperToolsWidth(_ width: CGFloat, containerBounds: NSRect) {
        let normalizedWidth = max(0, width)
        preferredAttachedDeveloperToolsWidth = normalizedWidth
        guard containerBounds.width > 0 else {
            preferredAttachedDeveloperToolsWidthFraction = nil
            return
        }
        preferredAttachedDeveloperToolsWidthFraction = normalizedWidth / containerBounds.width
    }

    func preferredAttachedDeveloperToolsWidthState() -> (width: CGFloat?, widthFraction: CGFloat?) {
        (preferredAttachedDeveloperToolsWidth, preferredAttachedDeveloperToolsWidthFraction)
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

    func currentPageZoomFactor() -> CGFloat {
        webView.pageZoom
    }

    @discardableResult
    func setPageZoomFactor(_ pageZoom: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, pageZoom))
        return applyPageZoom(clamped)
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

    // MARK: - Find in Page

    func startFind() {
        preferredFocusIntent = .findField
        let created = searchState == nil
        if created {
            searchState = BrowserSearchState()
        }
        let generation = beginSearchFocusRequest(reason: "startFind")
#if DEBUG
        let window = webView.window
        dlog(
            "browser.find.start panel=\(id.uuidString.prefix(5)) " +
            "created=\(created ? 1 : 0) render=\(shouldRenderWebView ? 1 : 0) " +
            "generation=\(generation) " +
            "window=\(window?.windowNumber ?? -1) key=\(NSApp.keyWindow === window ? 1 : 0) " +
            "firstResponder=\(String(describing: window?.firstResponder))"
        )
#endif
        postBrowserSearchFocusNotification(reason: "immediate", generation: generation)
        // Focus notification can race with portal overlay mount. Re-post on the
        // next runloop and shortly after so the find field can claim first responder.
        DispatchQueue.main.async { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async0", generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async50ms", generation: generation)
        }
    }

    private func postBrowserSearchFocusNotification(reason: String, generation: UInt64) {
        guard canApplySearchFocusRequest(generation) else {
#if DEBUG
            dlog(
                "browser.find.focusNotification.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) generation=\(generation)"
            )
#endif
            return
        }
#if DEBUG
        let window = webView.window
        dlog(
            "browser.find.focusNotification panel=\(id.uuidString.prefix(5)) " +
            "generation=\(generation) " +
            "reason=\(reason) window=\(window?.windowNumber ?? -1) " +
            "firstResponder=\(String(describing: window?.firstResponder))"
        )
#endif
        NotificationCenter.default.post(name: .browserSearchFocus, object: id)
    }

    func findNext() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.webView.evaluateJavaScript(BrowserFindJavaScript.nextScript())
            self.parseFindResult(result)
        }
    }

    func findPrevious() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.webView.evaluateJavaScript(BrowserFindJavaScript.previousScript())
            self.parseFindResult(result)
        }
    }

    func hideFind() {
        invalidateSearchFocusRequests(reason: "hideFind")
        searchState = nil
    }

    private func restoreFindStateAfterNavigation(replaySearch: Bool) {
        guard let state = searchState else { return }
        state.total = nil
        state.selected = nil
        if replaySearch, !state.needle.isEmpty {
            executeFindSearch(state.needle)
        }
        postBrowserSearchFocusNotification(
            reason: "restoreAfterNavigation",
            generation: searchFocusRequestGeneration
        )
    }

    private func executeFindSearch(_ needle: String) {
        guard !needle.isEmpty else {
            executeFindClear()
            searchState?.selected = nil
            searchState?.total = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let js = BrowserFindJavaScript.searchScript(query: needle)
            do {
                let result = try await self.webView.evaluateJavaScript(js)
                self.parseFindResult(result)
            } catch {
                NSLog("Find: browser JS search error: %@", error.localizedDescription)
            }
        }
    }

    private func executeFindClear() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.webView.evaluateJavaScript(BrowserFindJavaScript.clearScript())
            } catch {
                NSLog("Find: browser JS clear error: %@", error.localizedDescription)
            }
        }
    }

    private func parseFindResult(_ result: Any?) {
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = json["total"] as? Int,
              let current = json["current"] as? Int,
              total >= 0, current >= 0 else {
            return
        }
        searchState?.total = UInt(total)
        searchState?.selected = total > 0 ? UInt(current) : nil
    }

    func setBrowserThemeMode(_ mode: BrowserThemeMode) {
        browserThemeMode = mode
        applyBrowserThemeModeIfNeeded()
    }

    func refreshAppearanceDrivenColors() {
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
    }

    func suppressOmnibarAutofocus(for seconds: TimeInterval) {
        suppressOmnibarAutofocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        dlog(
            "browser.focus.omnibarAutofocus.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func suppressWebViewFocus(for seconds: TimeInterval) {
        suppressWebViewFocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        dlog(
            "browser.focus.webView.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func clearWebViewFocusSuppression() {
        suppressWebViewFocusUntil = nil
#if DEBUG
        dlog("browser.focus.webView.suppress.clear panel=\(id.uuidString.prefix(5))")
#endif
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
        if searchState != nil {
            return true
        }
        if let until = suppressWebViewFocusUntil {
            return Date() < until
        }
        return false
    }

    func beginSuppressWebViewFocusForAddressBar() {
        let enteringAddressBar = !suppressWebViewFocusForAddressBar
        if enteringAddressBar {
#if DEBUG
            dlog("browser.focus.addressBarSuppress.begin panel=\(id.uuidString.prefix(5))")
#endif
            invalidateAddressBarPageFocusRestoreAttempts()
        }
        suppressWebViewFocusForAddressBar = true
        if enteringAddressBar {
            captureAddressBarPageFocusIfNeeded()
        }
    }

    func endSuppressWebViewFocusForAddressBar() {
        if suppressWebViewFocusForAddressBar {
#if DEBUG
            dlog("browser.focus.addressBarSuppress.end panel=\(id.uuidString.prefix(5))")
#endif
        }
        suppressWebViewFocusForAddressBar = false
    }

    @discardableResult
    func requestAddressBarFocus() -> UUID {
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "requestAddressBarFocus")
        beginSuppressWebViewFocusForAddressBar()
        if let pendingAddressBarFocusRequestId {
#if DEBUG
            dlog(
                "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
                "request=\(pendingAddressBarFocusRequestId.uuidString.prefix(8)) result=reuse_pending"
            )
#endif
            return pendingAddressBarFocusRequestId
        }
        let requestId = UUID()
        pendingAddressBarFocusRequestId = requestId
#if DEBUG
        dlog(
            "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) result=new"
        )
#endif
        return requestId
    }

    func noteWebViewFocused() {
        guard searchState == nil else { return }
        guard preferredFocusIntent != .webView else { return }
        preferredFocusIntent = .webView
        invalidateSearchFocusRequests(reason: "webViewFocused")
    }

    func noteAddressBarFocused() {
        guard preferredFocusIntent != .addressBar else { return }
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "addressBarFocused")
    }

    func noteFindFieldFocused() {
        guard preferredFocusIntent != .findField else { return }
        preferredFocusIntent = .findField
    }

    func canApplySearchFocusRequest(_ generation: UInt64) -> Bool {
        generation != 0 &&
            generation == searchFocusRequestGeneration &&
            searchState != nil &&
            preferredFocusIntent == .findField
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        if pendingAddressBarFocusRequestId != nil || AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id {
            return .browser(.addressBar)
        }

        if searchState != nil && preferredFocusIntent == .findField {
            return .browser(.findField)
        }

        if let window,
           Self.responderChainContains(window.firstResponder, target: webView) {
            return .browser(.webView)
        }

        return .browser(preferredFocusIntent)
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        if pendingAddressBarFocusRequestId != nil {
            return .browser(.addressBar)
        }
        if searchState != nil && preferredFocusIntent == .findField {
            return .browser(.findField)
        }
        return .browser(preferredFocusIntent)
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard case .browser(let target) = intent else { return }

        switch target {
        case .webView:
            preferredFocusIntent = .webView
            invalidateSearchFocusRequests(reason: "prepareWebView")
            endSuppressWebViewFocusForAddressBar()
        case .addressBar:
            preferredFocusIntent = .addressBar
            invalidateSearchFocusRequests(reason: "prepareAddressBar")
            beginSuppressWebViewFocusForAddressBar()
        case .findField:
            preferredFocusIntent = .findField
        }
#if DEBUG
        dlog(
            "browser.focus.prepare panel=\(id.uuidString.prefix(5)) " +
            "target=\(String(describing: target)) suppressWeb=\(shouldSuppressWebViewFocus() ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard case .browser(let target) = intent else { return false }

        switch target {
        case .webView:
            noteWebViewFocused()
            focus()
            return true
        case .addressBar:
            let requestId = requestAddressBarFocus()
            NotificationCenter.default.post(name: .browserFocusAddressBar, object: id)
#if DEBUG
            dlog(
                "browser.focus.restore panel=\(id.uuidString.prefix(5)) " +
                "target=addressBar request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return true
        case .findField:
            startFind()
            return true
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        if AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id {
            return .browser(.addressBar)
        }

        if BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: window) == id {
            return .browser(.findField)
        }

        if Self.responderChainContains(responder, target: webView) {
            return .browser(.webView)
        }

        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard case .browser(let target) = intent else { return false }

        switch target {
        case .findField:
            invalidateSearchFocusRequests(reason: "yieldFindField")
            let yielded = BrowserWindowPortalRegistry.yieldSearchOverlayFocusIfOwned(by: id, in: window)
#if DEBUG
            if yielded {
                dlog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=browserFind")
            }
#endif
            return yielded
        case .addressBar:
            guard AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id else { return false }
            let yielded = window.makeFirstResponder(nil)
#if DEBUG
            if yielded {
                dlog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=addressBar")
            }
#endif
            return yielded
        case .webView:
            guard Self.responderChainContains(window.firstResponder, target: webView) else { return false }
            return window.makeFirstResponder(nil)
        }
    }

    @discardableResult
    private func beginSearchFocusRequest(reason: String) -> UInt64 {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        dlog(
            "browser.find.focusLease.begin panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
        return searchFocusRequestGeneration
    }

    private func invalidateSearchFocusRequests(reason: String) {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        dlog(
            "browser.find.focusLease.invalidate panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
    }

    func acknowledgeAddressBarFocusRequest(_ requestId: UUID) {
        guard pendingAddressBarFocusRequestId == requestId else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.requestAck panel=\(id.uuidString.prefix(5)) " +
                "request=\(requestId.uuidString.prefix(8)) result=ignored " +
                "pending=\(pendingAddressBarFocusRequestId?.uuidString.prefix(8) ?? "nil")"
            )
#endif
            return
        }
        pendingAddressBarFocusRequestId = nil
#if DEBUG
        dlog(
            "browser.focus.addressBar.requestAck panel=\(id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) result=cleared"
        )
#endif
    }

    private func captureAddressBarPageFocusIfNeeded() {
        webView.evaluateJavaScript(Self.addressBarFocusCaptureScript) { [weak self] result, error in
#if DEBUG
            guard let self else { return }
            if let error {
                dlog(
                    "browser.focus.addressBar.capture panel=\(self.id.uuidString.prefix(5)) " +
                    "result=error message=\(error.localizedDescription)"
                )
                return
            }
            let resultValue = (result as? String) ?? "unknown"
            dlog(
                "browser.focus.addressBar.capture panel=\(self.id.uuidString.prefix(5)) " +
                "result=\(resultValue)"
            )
#else
            _ = self
            _ = result
            _ = error
#endif
        }
    }

    private enum AddressBarPageFocusRestoreStatus: String {
        case restored
        case noState = "no_state"
        case missingTarget = "missing_target"
        case notFocused = "not_focused"
        case error
    }

    private static func addressBarPageFocusRestoreStatus(
        from result: Any?,
        error: Error?
    ) -> AddressBarPageFocusRestoreStatus {
        if error != nil { return .error }
        guard let raw = result as? String else { return .error }
        return AddressBarPageFocusRestoreStatus(rawValue: raw) ?? .error
    }

    func invalidateAddressBarPageFocusRestoreAttempts() {
        addressBarFocusRestoreGeneration &+= 1
#if DEBUG
        dlog(
            "browser.focus.addressBar.restore.invalidate panel=\(id.uuidString.prefix(5)) " +
            "generation=\(addressBarFocusRestoreGeneration)"
        )
#endif
    }

    func restoreAddressBarPageFocusIfNeeded(completion: @escaping (Bool) -> Void) {
        addressBarFocusRestoreGeneration &+= 1
        let generation = addressBarFocusRestoreGeneration
        let delays: [TimeInterval] = [0.0, 0.03, 0.09, 0.2]
        restoreAddressBarPageFocusAttemptIfNeeded(
            attempt: 0,
            delays: delays,
            generation: generation,
            completion: completion
        )
    }

    private func restoreAddressBarPageFocusAttemptIfNeeded(
        attempt: Int,
        delays: [TimeInterval],
        generation: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard generation == addressBarFocusRestoreGeneration else {
            completion(false)
            return
        }
        webView.evaluateJavaScript(Self.addressBarFocusRestoreScript) { [weak self] result, error in
            guard let self else {
                completion(false)
                return
            }
            guard generation == self.addressBarFocusRestoreGeneration else {
                completion(false)
                return
            }

            let status = Self.addressBarPageFocusRestoreStatus(from: result, error: error)
            let canRetry = (status == .notFocused || status == .error)
            let hasNextAttempt = attempt + 1 < delays.count

#if DEBUG
            if let error {
                dlog(
                    "browser.focus.addressBar.restore panel=\(self.id.uuidString.prefix(5)) " +
                    "attempt=\(attempt) status=\(status.rawValue) " +
                    "message=\(error.localizedDescription)"
                )
            } else {
                dlog(
                    "browser.focus.addressBar.restore panel=\(self.id.uuidString.prefix(5)) " +
                    "attempt=\(attempt) status=\(status.rawValue)"
                )
            }
#endif

            if status == .restored {
                completion(true)
                return
            }

            if canRetry && hasNextAttempt {
                let delay = delays[attempt + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard generation == self.addressBarFocusRestoreGeneration else {
                        completion(false)
                        return
                    }
                    self.restoreAddressBarPageFocusAttemptIfNeeded(
                        attempt: attempt + 1,
                        delays: delays,
                        generation: generation,
                        completion: completion
                    )
                }
                return
            }

            completion(false)
        }
    }

    /// Returns the most reliable URL string for omnibar-related matching and UI decisions.
    /// `currentURL` can lag behind navigation changes, so prefer the live WKWebView URL.
    func preferredURLStringForOmnibar() -> String? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url)?.absoluteString
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

    private func resolvedCurrentSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           Self.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           Self.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return restoredHistoryCurrentURL
    }

    private func refreshNavigationAvailability() {
        let resolvedCanGoBack: Bool
        let resolvedCanGoForward: Bool
        if usesRestoredSessionHistory {
            resolvedCanGoBack = !restoredBackHistoryStack.isEmpty
            resolvedCanGoForward = !restoredForwardHistoryStack.isEmpty
        } else {
            resolvedCanGoBack = nativeCanGoBack
            resolvedCanGoForward = nativeCanGoForward
        }

        if canGoBack != resolvedCanGoBack {
            canGoBack = resolvedCanGoBack
        }
        if canGoForward != resolvedCanGoForward {
            canGoForward = resolvedCanGoForward
        }
    }

    private func abandonRestoredSessionHistoryIfNeeded() {
        guard usesRestoredSessionHistory else { return }
        usesRestoredSessionHistory = false
        restoredBackHistoryStack.removeAll(keepingCapacity: false)
        restoredForwardHistoryStack.removeAll(keepingCapacity: false)
        restoredHistoryCurrentURL = nil
        refreshNavigationAvailability()
    }

    private static func serializableSessionHistoryURLString(_ url: URL?) -> String? {
        guard let url else { return nil }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "about:blank" else { return nil }
        return value
    }

    private static func sanitizedSessionHistoryURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "about:blank" else { return nil }
        return URL(string: trimmed)
    }

    private static func sanitizedSessionHistoryURLs(_ values: [String]) -> [URL] {
        values.compactMap { sanitizedSessionHistoryURL($0) }
    }

}

private extension BrowserPanel {
    func applyBrowserThemeModeIfNeeded() {
        switch browserThemeMode {
        case .system:
            webView.appearance = nil
        case .light:
            webView.appearance = NSAppearance(named: .aqua)
        case .dark:
            webView.appearance = NSAppearance(named: .darkAqua)
        }

        let script = makeBrowserThemeModeScript(mode: browserThemeMode)
        webView.evaluateJavaScript(script) { _, error in
            #if DEBUG
            if let error {
                dlog("browser.themeMode error=\(error.localizedDescription)")
            }
            #endif
        }
    }

    func makeBrowserThemeModeScript(mode: BrowserThemeMode) -> String {
        let colorSchemeLiteral: String
        switch mode {
        case .system:
            colorSchemeLiteral = "null"
        case .light:
            colorSchemeLiteral = "'light'"
        case .dark:
            colorSchemeLiteral = "'dark'"
        }

        return """
        (() => {
          const metaId = 'cmux-browser-theme-mode-meta';
          const colorScheme = \(colorSchemeLiteral);
          const root = document.documentElement || document.body;
          if (!root) return;

          let meta = document.getElementById(metaId);
          if (colorScheme) {
            root.style.setProperty('color-scheme', colorScheme, 'important');
            root.setAttribute('data-cmux-browser-theme', colorScheme);
            if (!meta) {
              meta = document.createElement('meta');
              meta.id = metaId;
              meta.name = 'color-scheme';
              (document.head || root).appendChild(meta);
            }
            meta.setAttribute('content', colorScheme);
          } else {
            root.style.removeProperty('color-scheme');
            root.removeAttribute('data-cmux-browser-theme');
            if (meta) {
              meta.remove();
            }
          }
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
    func configureInsecureHTTPAlertHooksForTesting(
        alertFactory: @escaping () -> NSAlert,
        windowProvider: @escaping () -> NSWindow?
    ) {
        insecureHTTPAlertFactory = alertFactory
        insecureHTTPAlertWindowProvider = windowProvider
    }

    func resetInsecureHTTPAlertHooksForTesting() {
        insecureHTTPAlertFactory = { NSAlert() }
        insecureHTTPAlertWindowProvider = { [weak self] in
            self?.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
    }

    func presentInsecureHTTPAlertForTesting(
        url: URL,
        recordTypedNavigation: Bool = false
    ) {
        presentInsecureHTTPAlert(
            for: URLRequest(url: url),
            intent: .currentTab,
            recordTypedNavigation: recordTypedNavigation
        )
    }

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
        let transitionTarget = developerToolsTransitionTargetVisible.map { $0 ? "1" : "0" } ?? "nil"
        let pendingTarget = pendingDeveloperToolsTransitionTargetVisible.map { $0 ? "1" : "0" } ?? "nil"
        return "pref=\(preferred) vis=\(visible) inspector=\(inspector) attached=\(attached) inWindow=\(inWindow) restoreRetry=\(developerToolsRestoreRetryAttempt) forceRefresh=\(forceRefresh) tx=\(transitionTarget) pending=\(pendingTarget)"
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

    func hasSideDockedDeveloperToolsLayout() -> Bool {
        guard let container = webView.superview else { return false }
        return Self.visibleDescendants(in: container)
            .filter { Self.isVisibleSideDockInspectorCandidate($0) && Self.isInspectorView($0) }
            .contains { inspectorCandidate in
                hasSideDockedInspectorSibling(startingAt: inspectorCandidate, root: container)
            }
    }

    func hasSideDockedInspectorSibling(startingAt inspectorLeaf: NSView, root: NSView) -> Bool {
        var current: NSView? = inspectorLeaf

        while let inspectorView = current, inspectorView !== root {
            guard let containerView = inspectorView.superview else { break }
            let hasSideDockedSibling = containerView.subviews.contains { candidate in
                guard Self.isVisibleSideDockSiblingCandidate(candidate) else { return false }
                guard candidate !== inspectorView else { return false }
                let horizontallyAdjacent =
                    candidate.frame.maxX <= inspectorView.frame.minX + 1 ||
                    candidate.frame.minX >= inspectorView.frame.maxX - 1
                guard horizontallyAdjacent else { return false }
                return Self.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8
            }
            if hasSideDockedSibling {
                return true
            }

            current = containerView
        }

        return false
    }

    static func visibleDescendants(in root: NSView) -> [NSView] {
        var descendants: [NSView] = []
        var stack = Array(root.subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }

    static func isInspectorView(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("WKInspector")
    }

    static func isVisibleSideDockInspectorCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    static func isVisibleSideDockSiblingCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }
}

extension BrowserPanel {
    func hideBrowserPortalView(source: String) {
        BrowserWindowPortalRegistry.hide(
            webView: webView,
            source: source
        )
    }
}

extension WKWebView {
    func cmuxInspectorObject() -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector),
              let inspector = perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        return inspector
    }

    func cmuxInspectorFrontendWebView() -> WKWebView? {
        guard let inspector = cmuxInspectorObject() else { return nil }
        let selector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: selector),
              let inspectorWebView = inspector.perform(selector)?.takeUnretainedValue() as? WKWebView else {
            return nil
        }
        return inspectorWebView
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
class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
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

func browserNavigationShouldOpenInNewTab(
    navigationType: WKNavigationType,
    modifierFlags: NSEvent.ModifierFlags,
    buttonNumber: Int,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
) -> Bool {
    guard navigationType == .linkActivated || navigationType == .other else {
        return false
    }

    if modifierFlags.contains(.command) {
        return true
    }
    if buttonNumber == 2 {
        return true
    }
    // In some WebKit paths, middle-click arrives as buttonNumber=4.
    // Recover intent when we just observed a local middle-click.
    if buttonNumber == 4, hasRecentMiddleClickIntent {
        return true
    }

    // WebKit can omit buttonNumber for middle-click link activations.
    if let currentEventType,
       (currentEventType == .otherMouseDown || currentEventType == .otherMouseUp),
       currentEventButtonNumber == 2 {
        return true
    }
    return false
}

func browserNavigationShouldCreatePopup(
    navigationType: WKNavigationType,
    modifierFlags: NSEvent.ModifierFlags,
    buttonNumber: Int,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
) -> Bool {
    let isUserNewTab = browserNavigationShouldOpenInNewTab(
        navigationType: navigationType,
        modifierFlags: modifierFlags,
        buttonNumber: buttonNumber,
        hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
        currentEventType: currentEventType,
        currentEventButtonNumber: currentEventButtonNumber
    )
    return navigationType == .other && !isUserNewTab
}

func browserNavigationShouldFallbackNilTargetToNewTab(
    navigationType: WKNavigationType
) -> Bool {
    // Scripted popups rely on WKUIDelegate.createWebViewWith returning a live
    // web view so window.opener/postMessage remain intact across OAuth flows.
    navigationType != .other
}

private class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    var didFinish: ((WKWebView) -> Void)?
    var didFailNavigation: ((WKWebView, String) -> Void)?
    var didTerminateWebContentProcess: ((WKWebView) -> Void)?
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
        // Treat committed-navigation failures the same as provisional ones so
        // stale favicon/title state from the prior page gets cleared.
        let failedURL = webView.url?.absoluteString ?? ""
        didFailNavigation?(webView, failedURL)
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

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // WKWebView rejects all authentication challenges by default when this
        // delegate method is not implemented (.rejectProtectionSpace). This
        // breaks TLS client-certificate flows such as Microsoft Entra ID
        // Conditional Access, which verifies device compliance via a client
        // certificate stored in the system keychain by MDM enrollment.
        //
        // By returning .performDefaultHandling the system's standard URL-loading
        // behaviour takes over: the keychain is searched for matching client
        // identities, MDM-installed root CAs are trusted, and any configured SSO
        // extensions (e.g. Microsoft Enterprise SSO) can intercept the challenge.
        completionHandler(.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
#if DEBUG
        dlog("browser.webcontent.terminated panel=\(String(describing: self))")
#endif
        didTerminateWebContentProcess?(webView)
    }

    private func loadErrorPage(in webView: WKWebView, failedURL: String, error: NSError) {
        let title: String
        let message: String

        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorTimedOut):
            title = String(localized: "browser.error.cantReach.title", defaultValue: "Can\u{2019}t reach this page")
            if failedURL.isEmpty {
                message = String(localized: "browser.error.cantReach.messageSite", defaultValue: "The site refused to connect. Check that a server is running on this address.")
            } else {
                message = String(localized: "browser.error.cantReach.messageURL", defaultValue: "\(failedURL) refused to connect. Check that a server is running on this address.")
            }
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            title = String(localized: "browser.error.noInternet", defaultValue: "No internet connection")
            message = String(localized: "browser.error.checkNetwork", defaultValue: "Check your network connection and try again.")
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            title = String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
            message = String(localized: "browser.error.invalidCertificate", defaultValue: "The certificate for this site is invalid.")
        default:
            title = String(localized: "browser.error.cantOpen.title", defaultValue: "Can\u{2019}t open this page")
            message = error.localizedDescription
        }

        let escapeHTML: (String) -> String = { value in
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        let escapedTitle = escapeHTML(title)
        let escapedMessage = escapeHTML(message)
        let escapedURL = escapeHTML(failedURL)
        let escapedReloadLabel = escapeHTML(String(localized: "browser.error.reload", defaultValue: "Reload"))

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
            <h1>\(escapedTitle)</h1>
            <p>\(escapedMessage)</p>
            <div class="url">\(escapedURL)</div>
            <button onclick="location.reload()">\(escapedReloadLabel)</button>
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
        let hasRecentMiddleClickIntent = CmuxWebView.hasRecentMiddleClickIntent(for: webView)
        let shouldOpenInNewTab = browserNavigationShouldOpenInNewTab(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent
        )
#if DEBUG
        let currentEventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        let currentEventButton = NSApp.currentEvent.map { String($0.buttonNumber) } ?? "nil"
        let navType = String(describing: navigationAction.navigationType)
        dlog(
            "browser.nav.decidePolicy navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "eventType=\(currentEventType) eventButton=\(currentEventButton) " +
            "recentMiddleIntent=\(hasRecentMiddleClickIntent ? 1 : 0) " +
            "openInNewTab=\(shouldOpenInNewTab ? 1 : 0)"
        )
#endif

        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false,
           shouldBlockInsecureHTTPNavigation?(url) == true {
            let intent: BrowserInsecureHTTPNavigationIntent
            if shouldOpenInNewTab || navigationAction.targetFrame == nil {
                intent = .newTab
            } else {
                intent = .currentTab
            }
#if DEBUG
            dlog(
                "browser.nav.decidePolicy.action kind=blockedInsecure intent=\(intent == .newTab ? "newTab" : "currentTab") " +
                "url=\(url.absoluteString)"
            )
#endif
            handleBlockedInsecureHTTPNavigation?(navigationAction.request, intent)
            decisionHandler(.cancel)
            return
        }

        // WebKit cannot open app-specific deeplinks (discord://, slack://, zoommtg://, etc.).
        // Hand these off to macOS so the owning app can handle them.
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false,
           browserShouldOpenURLExternally(url) {
            let opened = NSWorkspace.shared.open(url)
            if !opened {
                NSLog("BrowserPanel external navigation failed to open URL: %@", url.absoluteString)
            }
            #if DEBUG
            dlog("browser.navigation.external source=navDelegate opened=\(opened ? 1 : 0) url=\(url.absoluteString)")
            #endif
            decisionHandler(.cancel)
            return
        }

        // Cmd+click and middle-click on regular links should always open in a new tab.
        if shouldOpenInNewTab,
           let url = navigationAction.request.url {
#if DEBUG
            dlog("browser.nav.decidePolicy.action kind=openInNewTab url=\(url.absoluteString)")
#endif
            openInNewTab?(url)
            decisionHandler(.cancel)
            return
        }

        // target=_blank link navigations should open in a new tab.
        // Scripted popups (navigationType == .other) are handled in
        // WKUIDelegate.createWebViewWith so OAuth opener linkage survives.
        if navigationAction.targetFrame == nil,
           browserNavigationShouldFallbackNilTargetToNewTab(
               navigationType: navigationAction.navigationType
           ),
           let url = navigationAction.request.url {
#if DEBUG
            dlog("browser.nav.decidePolicy.action kind=openInNewTabFromNilTarget url=\(url.absoluteString)")
#endif
            openInNewTab?(url)
            decisionHandler(.cancel)
            return
        }

#if DEBUG
        let targetURL = navigationAction.request.url?.absoluteString ?? "nil"
        dlog("browser.nav.decidePolicy.action kind=allow url=\(targetURL)")
#endif
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
    var openPopup: ((WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?)?

    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
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

    /// Called when the page requests a new window (window.open(), target=_blank, etc.).
    ///
    /// Returns a live popup WKWebView created with WebKit's supplied configuration
    /// to preserve popup browsing-context semantics (window.opener, postMessage).
    /// Falls back to new-tab behavior only if popup creation is unavailable.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
#if DEBUG
        let currentEventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        let currentEventButton = NSApp.currentEvent.map { String($0.buttonNumber) } ?? "nil"
        let navType = String(describing: navigationAction.navigationType)
        dlog(
            "browser.nav.createWebView navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "eventType=\(currentEventType) eventButton=\(currentEventButton)"
        )
#endif
        // External URL schemes → hand off to macOS, don't create a popup
        if let url = navigationAction.request.url,
           browserShouldOpenURLExternally(url) {
            let opened = NSWorkspace.shared.open(url)
            if !opened {
                NSLog("BrowserPanel external navigation failed to open URL: %@", url.absoluteString)
            }
            #if DEBUG
            dlog("browser.navigation.external source=uiDelegate opened=\(opened ? 1 : 0) url=\(url.absoluteString)")
            #endif
            return nil
        }

        // Classifier: only scripted requests (window.open()) get popup windows.
        // User-initiated actions (link clicks, context menu "Open Link in New Tab",
        // Cmd+click, middle-click) fall through to existing new-tab behavior.
        //
        // WebKit sometimes delivers .other for Cmd+click / middle-click, so we
        // reuse browserNavigationShouldOpenInNewTab to recover user intent before
        // treating .other as a scripted popup.
        let isScriptedPopup = browserNavigationShouldCreatePopup(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: CmuxWebView.hasRecentMiddleClickIntent(for: webView)
        )

        if isScriptedPopup, let popupWebView = openPopup?(configuration, windowFeatures) {
#if DEBUG
            dlog("browser.nav.createWebView.action kind=popup")
#endif
            return popupWebView
        }

        // Fallback: open in new tab (no opener linkage)
        if let url = navigationAction.request.url {
            if let requestNavigation {
                let intent: BrowserInsecureHTTPNavigationIntent = .newTab
#if DEBUG
                dlog(
                    "browser.nav.createWebView.action kind=requestNavigation intent=newTab " +
                    "url=\(url.absoluteString)"
                )
#endif
                requestNavigation(navigationAction.request, intent)
            } else {
#if DEBUG
                dlog("browser.nav.createWebView.action kind=openInNewTab url=\(url.absoluteString)")
#endif
                openInNewTab?(url)
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
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
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
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
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
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
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
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

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
    case historyOnly
    case cookiesAndHistory
    case everything

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cookiesOnly:
            return String(localized: "browser.import.scope.cookiesOnly", defaultValue: "Cookies only")
        case .historyOnly:
            return String(localized: "browser.import.scope.historyOnly", defaultValue: "History only")
        case .cookiesAndHistory:
            return String(localized: "browser.import.scope.cookiesAndHistory", defaultValue: "Cookies + history")
        case .everything:
            return String(localized: "browser.import.scope.everything", defaultValue: "Everything")
        }
    }

    var includesCookies: Bool {
        switch self {
        case .cookiesOnly, .cookiesAndHistory, .everything:
            return true
        case .historyOnly:
            return false
        }
    }

    var includesHistory: Bool {
        switch self {
        case .cookiesOnly:
            return false
        case .historyOnly, .cookiesAndHistory, .everything:
            return true
        }
    }

    static func fromSelection(
        includeCookies: Bool,
        includeHistory: Bool,
        includeAdditionalData: Bool
    ) -> BrowserImportScope? {
        if includeAdditionalData {
            return .everything
        }
        guard includeCookies || includeHistory else { return nil }
        if includeCookies && includeHistory {
            return .cookiesAndHistory
        }
        if includeCookies {
            return .cookiesOnly
        }
        return .historyOnly
    }
}

enum BrowserImportEngineFamily: String, Hashable {
    case chromium
    case firefox
    case webkit
}

struct InstalledBrowserProfile: Identifiable, Hashable {
    let displayName: String
    let rootURL: URL
    let isDefault: Bool

    var id: String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
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
    let resolvedFamily: BrowserImportEngineFamily
    let homeDirectoryURL: URL
    let appURL: URL?
    let dataRootURL: URL?
    let profiles: [InstalledBrowserProfile]
    let detectionSignals: [String]
    let detectionScore: Int

    var id: String { descriptor.id }
    var displayName: String { descriptor.displayName }
    var family: BrowserImportEngineFamily { resolvedFamily }
    var profileURLs: [URL] { profiles.map(\.rootURL) }
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
            family: .chromium,
            tier: 3,
            bundleIdentifiers: ["net.imput.helium", "com.jadenGeller.Helium", "com.jaden.geller.helium"],
            appNames: ["Helium.app"],
            dataRootRelativePaths: [
                "Library/Application Support/net.imput.helium",
                "Library/Application Support/Helium",
            ],
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
                appBundleIdentifier: appDetection.bundleIdentifier,
                fileManager: fileManager
            )

            if appDetection.url == nil,
               !descriptor.supportsDataOnlyDetection {
                return nil
            }

            let hasData = dataDetection.dataRootURL != nil || !dataDetection.profiles.isEmpty || !dataDetection.artifactHits.isEmpty
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
            score += min(24, dataDetection.profiles.count * 6)
            score += min(16, dataDetection.artifactHits.count * 4)

            var signals: [String] = []
            signals.append(contentsOf: appDetection.signals)
            if let root = dataDetection.dataRootURL {
                signals.append("data:\(root.lastPathComponent)")
            }
            if !dataDetection.profiles.isEmpty {
                signals.append("profiles:\(dataDetection.profiles.count)")
            }
            if !dataDetection.artifactHits.isEmpty {
                signals.append(contentsOf: dataDetection.artifactHits.map { "artifact:\($0)" })
            }

            return InstalledBrowserCandidate(
                descriptor: descriptor,
                resolvedFamily: dataDetection.family,
                homeDirectoryURL: homeDirectoryURL,
                appURL: appDetection.url,
                dataRootURL: dataDetection.dataRootURL,
                profiles: dataDetection.profiles,
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
        guard !browsers.isEmpty else {
            return String(
                localized: "browser.import.detected.none",
                defaultValue: "No supported browsers detected."
            )
        }
        let names = browsers.map(\.displayName)
        if names.count <= limit {
            return String(
                format: String(
                    localized: "browser.import.detected.all",
                    defaultValue: "Detected: %@."
                ),
                names.joined(separator: ", ")
            )
        }
        let shown = names.prefix(limit).joined(separator: ", ")
        let remaining = names.count - limit
        if remaining == 1 {
            return String(
                format: String(
                    localized: "browser.import.detected.more.one",
                    defaultValue: "Detected: %@, +1 more."
                ),
                shown
            )
        }
        return String(
            format: String(
                localized: "browser.import.detected.more.other",
                defaultValue: "Detected: %@, +%ld more."
            ),
            shown,
            remaining
        )
    }

    private static func detectApplication(
        descriptor: BrowserImportBrowserDescriptor,
        appSearchDirectories: [URL],
        bundleLookup: BundleLookup,
        fileManager: FileManager
    ) -> (url: URL?, signals: [String], bundleIdentifier: String?) {
        for knownBundleIdentifier in descriptor.bundleIdentifiers {
            if let appURL = bundleLookup(knownBundleIdentifier) {
                return (appURL, ["bundle:\(knownBundleIdentifier)"], bundleIdentifier(for: appURL) ?? knownBundleIdentifier)
            }
        }

        for appName in descriptor.appNames {
            for directory in appSearchDirectories {
                let appURL = directory.appendingPathComponent(appName, isDirectory: true)
                if fileManager.fileExists(atPath: appURL.path) {
                    return (appURL, ["app:\(appName)"], bundleIdentifier(for: appURL))
                }
            }
        }

        return (nil, [], nil)
    }

    private static func detectData(
        descriptor: BrowserImportBrowserDescriptor,
        homeDirectoryURL: URL,
        appBundleIdentifier: String?,
        fileManager: FileManager
    ) -> (dataRootURL: URL?, family: BrowserImportEngineFamily, profiles: [InstalledBrowserProfile], artifactHits: [String]) {
        var bestRootURL: URL?
        var bestFamily = descriptor.family
        var bestProfiles: [InstalledBrowserProfile] = []
        var bestArtifacts: [String] = []
        let candidateRootPaths = candidateDataRootRelativePaths(
            descriptor: descriptor,
            appBundleIdentifier: appBundleIdentifier
        )

        for relativePath in candidateRootPaths {
            let rootURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: rootURL.path) else { continue }

            let detectedProfiles = detectProfiles(
                descriptor: descriptor,
                rootURL: rootURL,
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )

            let score = scoreProfileDetection(
                family: detectedProfiles.family,
                profiles: detectedProfiles.profiles,
                preferredFamily: descriptor.family
            ) + 8
            let currentScore = scoreProfileDetection(
                family: bestFamily,
                profiles: bestProfiles,
                preferredFamily: descriptor.family
            ) + (bestRootURL == nil ? 0 : 8)
            if score > currentScore {
                bestRootURL = rootURL
                bestFamily = detectedProfiles.family
                bestProfiles = detectedProfiles.profiles
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
               let rootPath = candidateRootPaths.first {
                let rootURL = homeDirectoryURL.appendingPathComponent(rootPath, isDirectory: true)
                if fileManager.fileExists(atPath: rootURL.path) {
                    bestRootURL = rootURL
                }
            }
        }

        if bestProfiles.isEmpty, let bestRootURL {
            bestProfiles = [
                InstalledBrowserProfile(
                    displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
                    rootURL: bestRootURL,
                    isDefault: true
                )
            ]
        }

        return (
            dataRootURL: bestRootURL,
            family: bestFamily,
            profiles: sortProfiles(dedupedProfiles(bestProfiles)),
            artifactHits: bestArtifacts
        )
    }

    private static func detectProfiles(
        descriptor: BrowserImportBrowserDescriptor,
        rootURL: URL,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> (family: BrowserImportEngineFamily, profiles: [InstalledBrowserProfile]) {
        let candidates: [(BrowserImportEngineFamily, [InstalledBrowserProfile])] = [
            (.chromium, chromiumProfiles(rootURL: rootURL, fileManager: fileManager)),
            (.firefox, firefoxProfiles(rootURL: rootURL, fileManager: fileManager)),
            (.webkit, webKitProfiles(
                descriptor: descriptor,
                rootURL: rootURL,
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )),
        ]

        return candidates.max { lhs, rhs in
            let lhsScore = scoreProfileDetection(
                family: lhs.0,
                profiles: lhs.1,
                preferredFamily: descriptor.family
            )
            let rhsScore = scoreProfileDetection(
                family: rhs.0,
                profiles: rhs.1,
                preferredFamily: descriptor.family
            )
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return lhs.0.rawValue > rhs.0.rawValue
        } ?? (descriptor.family, [])
    }

    private static func bundleIdentifier(for appURL: URL) -> String? {
        Bundle(url: appURL)?.bundleIdentifier
    }

    private static func candidateDataRootRelativePaths(
        descriptor: BrowserImportBrowserDescriptor,
        appBundleIdentifier: String?
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ relativePath: String) {
            if seen.insert(relativePath).inserted {
                result.append(relativePath)
            }
        }

        for relativePath in descriptor.dataRootRelativePaths {
            append(relativePath)
        }

        let bundleIdentifiers = [appBundleIdentifier].compactMap { $0 } + descriptor.bundleIdentifiers
        for bundleIdentifier in bundleIdentifiers {
            append("Library/Application Support/\(bundleIdentifier)")
            append("Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/\(bundleIdentifier)")
        }

        return result
    }

    private static func scoreProfileDetection(
        family: BrowserImportEngineFamily,
        profiles: [InstalledBrowserProfile],
        preferredFamily: BrowserImportEngineFamily
    ) -> Int {
        var score = profiles.count * 10
        if family == preferredFamily {
            score += 3
        }
        if profiles.contains(where: \.isDefault) {
            score += 1
        }
        return score
    }

    private static func chromiumProfiles(
        rootURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
        let nameMap = chromiumProfileNameMap(rootURL: rootURL)
        var profiles: [InstalledBrowserProfile] = []
        if looksLikeChromiumProfile(rootURL: rootURL, fileManager: fileManager) {
            profiles.append(
                InstalledBrowserProfile(
                    displayName: chromiumProfileDisplayName(
                        directoryName: rootURL.lastPathComponent,
                        nameMap: nameMap,
                        isDefault: true
                    ),
                    rootURL: rootURL,
                    isDefault: true
                )
            )
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
                name.hasPrefix("Person ") ||
                nameMap[name] != nil
            if isLikelyProfile && looksLikeChromiumProfile(rootURL: child, fileManager: fileManager) {
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: chromiumProfileDisplayName(
                            directoryName: name,
                            nameMap: nameMap,
                            isDefault: name == "Default"
                        ),
                        rootURL: child,
                        isDefault: name == "Default"
                    )
                )
            }
        }

        return sortProfiles(dedupedProfiles(profiles))
    }

    private static func firefoxProfiles(
        rootURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
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
                    let directoryName = child.lastPathComponent
                    profiles.append(
                        InstalledBrowserProfile(
                            displayName: directoryName,
                            rootURL: child,
                            isDefault: directoryName.localizedCaseInsensitiveContains("default")
                        )
                    )
                }
            }
        }

        return sortProfiles(dedupedProfiles(profiles))
    }

    private static func firefoxProfilesFromINI(
        rootURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
        let iniURL = rootURL.appendingPathComponent("profiles.ini", isDirectory: false)
        guard let contents = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return []
        }

        let sections = parseINISections(contents: contents)
        var profiles: [InstalledBrowserProfile] = []
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
                let displayName = section["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: (displayName?.isEmpty == false ? displayName! : profileURL.lastPathComponent),
                        rootURL: profileURL,
                        isDefault: section["Default"] == "1"
                    )
                )
            }
        }
        return profiles
    }

    private static func parseINISections(contents: String) -> [[String: String]] {
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
        return sections
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

    private static func webKitProfiles(
        descriptor: BrowserImportBrowserDescriptor,
        rootURL: URL,
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> [InstalledBrowserProfile] {
        var profiles: [InstalledBrowserProfile] = []
        if looksLikeWebKitProfile(rootURL: rootURL, fileManager: fileManager) {
            profiles.append(
                InstalledBrowserProfile(
                    displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
                    rootURL: rootURL,
                    isDefault: true
                )
            )
        }

        var profileRoots = [rootURL.appendingPathComponent("Profiles", isDirectory: true)]
        if descriptor.id == "safari" {
            profileRoots.append(
                homeDirectoryURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Containers", isDirectory: true)
                    .appendingPathComponent("com.apple.Safari", isDirectory: true)
                    .appendingPathComponent("Data", isDirectory: true)
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Safari", isDirectory: true)
                    .appendingPathComponent("Profiles", isDirectory: true)
            )
        }

        var profileIndex = 1
        for profileRoot in dedupedCanonicalURLs(profileRoots) where fileManager.fileExists(atPath: profileRoot.path) {
            let children = (try? fileManager.contentsOfDirectory(
                at: profileRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard looksLikeWebKitProfile(rootURL: child, fileManager: fileManager) else { continue }
                profiles.append(
                    InstalledBrowserProfile(
                        displayName: webKitProfileDisplayName(
                            directoryName: child.lastPathComponent,
                            fallbackIndex: profileIndex
                        ),
                        rootURL: child,
                        isDefault: false
                    )
                )
                profileIndex += 1
            }
        }

        return sortProfiles(dedupedProfiles(profiles))
    }

    private static func chromiumProfileNameMap(rootURL: URL) -> [String: String] {
        let localStateURL = rootURL.appendingPathComponent("Local State", isDirectory: false)
        guard let data = try? Data(contentsOf: localStateURL),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileSection = jsonObject["profile"] as? [String: Any],
              let infoCache = profileSection["info_cache"] as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (directoryName, rawProfileInfo) in infoCache {
            guard let profileInfo = rawProfileInfo as? [String: Any],
                  let name = profileInfo["name"] as? String else {
                continue
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                result[directoryName] = trimmedName
            }
        }
        return result
    }

    private static func chromiumProfileDisplayName(
        directoryName: String,
        nameMap: [String: String],
        isDefault: Bool
    ) -> String {
        if let mappedName = nameMap[directoryName], !mappedName.isEmpty {
            return mappedName
        }
        if isDefault {
            return String(localized: "browser.profile.default", defaultValue: "Default")
        }
        return directoryName
    }

    private static func looksLikeWebKitProfile(rootURL: URL, fileManager: FileManager) -> Bool {
        let candidatePaths = [
            "History.db",
            "Cookies.binarycookies",
            "Cookies.sqlite",
            "WebsiteData",
            "LocalStorage",
        ]

        for candidatePath in candidatePaths {
            let url = rootURL.appendingPathComponent(candidatePath, isDirectory: candidatePath != "History.db" && candidatePath != "Cookies.binarycookies" && candidatePath != "Cookies.sqlite")
            if fileManager.fileExists(atPath: url.path) {
                return true
            }
        }
        return false
    }

    private static func webKitProfileDisplayName(directoryName: String, fallbackIndex: Int) -> String {
        if directoryName.caseInsensitiveCompare("Default") == .orderedSame {
            return String(localized: "browser.profile.default", defaultValue: "Default")
        }
        if UUID(uuidString: directoryName) != nil {
            return String(
                format: String(
                    localized: "browser.import.sourceProfile.fallback",
                    defaultValue: "Profile %ld"
                ),
                fallbackIndex
            )
        }
        return directoryName
    }

    private static func defaultApplicationSearchDirectories(homeDirectoryURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications/Setapp", isDirectory: true),
        ]
    }

    private static func dedupedProfiles(_ profiles: [InstalledBrowserProfile]) -> [InstalledBrowserProfile] {
        var seen = Set<String>()
        var result: [InstalledBrowserProfile] = []
        for profile in profiles {
            if seen.insert(profile.id).inserted {
                result.append(profile)
            }
        }
        return result
    }

    private static func sortProfiles(_ profiles: [InstalledBrowserProfile]) -> [InstalledBrowserProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

struct BrowserImportOutcomeEntry: Sendable {
    let sourceProfileNames: [String]
    let destinationProfileName: String
    let importedCookies: Int
    let skippedCookies: Int
    let importedHistoryEntries: Int
    let warnings: [String]
}

struct BrowserImportOutcome: Sendable {
    let browserName: String
    let scope: BrowserImportScope
    let domainFilters: [String]
    let createdDestinationProfileNames: [String]
    let entries: [BrowserImportOutcomeEntry]
    let warnings: [String]

    var totalImportedCookies: Int {
        entries.reduce(0) { $0 + $1.importedCookies }
    }

    var totalSkippedCookies: Int {
        entries.reduce(0) { $0 + $1.skippedCookies }
    }

    var totalImportedHistoryEntries: Int {
        entries.reduce(0) { $0 + $1.importedHistoryEntries }
    }
}

struct RealizedBrowserImportExecutionEntry: Sendable {
    let sourceProfiles: [InstalledBrowserProfile]
    let destinationProfileID: UUID
    let destinationProfileName: String
}

struct RealizedBrowserImportExecutionPlan: Sendable {
    let mode: BrowserImportDestinationMode
    let entries: [RealizedBrowserImportExecutionEntry]
    let createdProfiles: [BrowserProfileDefinition]
}

enum BrowserImportPlanRealizationError: LocalizedError {
    case missingDestinationProfile(UUID)
    case profileCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDestinationProfile:
            return String(
                localized: "browser.import.error.destinationMissing",
                defaultValue: "The selected cmux browser profile no longer exists. Pick a destination profile again."
            )
        case .profileCreationFailed(let name):
            return String(
                format: String(
                    localized: "browser.import.error.destinationCreateFailed",
                    defaultValue: "cmux could not create the destination profile \"%@\"."
                ),
                name
            )
        }
    }
}

enum BrowserImportOutcomeFormatter {
    static func lines(for outcome: BrowserImportOutcome) -> [String] {
        var lines: [String] = []
        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.browser",
                    defaultValue: "Browser: %@"
                ),
                outcome.browserName
            )
        )

        if outcome.entries.count == 1, let entry = outcome.entries.first {
            if !entry.sourceProfileNames.isEmpty {
                lines.append(
                    String(
                        format: String(
                            localized: "browser.import.complete.sourceProfiles",
                            defaultValue: "Source profiles: %@"
                        ),
                        entry.sourceProfileNames.joined(separator: ", ")
                    )
                )
            }
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.destinationProfile",
                        defaultValue: "Destination profile: %@"
                    ),
                    entry.destinationProfileName
                )
            )
        } else if !outcome.entries.isEmpty {
            lines.append(
                String(
                    localized: "browser.import.complete.profileMappings",
                    defaultValue: "Profile mappings:"
                )
            )
            for entry in outcome.entries {
                let sourceNames = entry.sourceProfileNames.joined(separator: ", ")
                lines.append(
                    String(
                        format: String(
                            localized: "browser.import.complete.profileMapping",
                            defaultValue: "%@ -> %@"
                        ),
                        sourceNames,
                        entry.destinationProfileName
                    )
                )
            }
        }

        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.scope",
                    defaultValue: "Scope: %@"
                ),
                outcome.scope.displayName
            )
        )
        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.importedCookies",
                    defaultValue: "Imported cookies: %ld"
                ),
                outcome.totalImportedCookies
            )
        )
        if outcome.totalSkippedCookies > 0 {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.skippedCookies",
                        defaultValue: "Skipped cookies: %ld"
                    ),
                    outcome.totalSkippedCookies
                )
            )
        }
        if outcome.scope.includesHistory {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.importedHistory",
                        defaultValue: "Imported history entries: %ld"
                    ),
                    outcome.totalImportedHistoryEntries
                )
            )
        }
        if !outcome.domainFilters.isEmpty {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.domainFilter",
                        defaultValue: "Domain filter: %@"
                    ),
                    outcome.domainFilters.joined(separator: ", ")
                )
            )
        }
        if !outcome.createdDestinationProfileNames.isEmpty {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.createdProfiles",
                        defaultValue: "Created cmux profiles: %@"
                    ),
                    outcome.createdDestinationProfileNames.joined(separator: ", ")
                )
            )
        }
        if !outcome.warnings.isEmpty {
            lines.append("")
            lines.append(
                String(
                    localized: "browser.import.complete.warnings",
                    defaultValue: "Warnings:"
                )
            )
            for warning in outcome.warnings {
                lines.append("- \(warning)")
            }
        }

        return lines
    }
}

enum BrowserImportDestinationMode: Equatable, Sendable {
    case singleDestination
    case separateProfiles
    case mergeIntoOne
}

enum BrowserImportDestinationRequest: Equatable, Sendable {
    case existing(UUID)
    case createNamed(String)
}

struct BrowserImportExecutionEntry: Equatable, Sendable {
    var sourceProfiles: [InstalledBrowserProfile]
    var destination: BrowserImportDestinationRequest
}

struct BrowserImportExecutionPlan: Equatable, Sendable {
    var mode: BrowserImportDestinationMode
    var entries: [BrowserImportExecutionEntry]
}

struct BrowserImportStep3Presentation: Equatable {
    let showsModeSelector: Bool
    let showsSeparateRows: Bool
    let showsSingleDestinationPicker: Bool

    init(plan: BrowserImportExecutionPlan) {
        showsModeSelector = plan.entries.count > 1 || plan.entries.contains { $0.sourceProfiles.count > 1 }
        showsSeparateRows = plan.mode == .separateProfiles
        showsSingleDestinationPicker = plan.mode != .separateProfiles
    }
}

struct BrowserImportSourceProfilesPresentation: Equatable {
    let scrollHeight: CGFloat
    let showsHelpText: Bool

    init(profileCount: Int) {
        let visibleRows = min(max(profileCount, 1), 5)
        let contentHeight = CGFloat(visibleRows * 26 + 14)
        scrollHeight = max(76, contentHeight)
        showsHelpText = profileCount > 1
    }
}

enum BrowserImportPlanResolver {
    @MainActor
    static func defaultPlan(
        selectedSourceProfiles: [InstalledBrowserProfile],
        destinationProfiles: [BrowserProfileDefinition],
        preferredSingleDestinationProfileID: UUID
    ) -> BrowserImportExecutionPlan {
        let resolvedSourceProfiles = selectedSourceProfiles.isEmpty ? [] : selectedSourceProfiles

        guard resolvedSourceProfiles.count > 1 else {
            let destinationRequest: BrowserImportDestinationRequest
            if let sourceProfile = resolvedSourceProfiles.first,
               let matchingProfile = matchingDestinationProfile(
                for: sourceProfile.displayName,
                destinationProfiles: destinationProfiles
               ) {
                destinationRequest = .existing(matchingProfile.id)
            } else {
                destinationRequest = .existing(preferredSingleDestinationProfileID)
            }

            return BrowserImportExecutionPlan(
                mode: .singleDestination,
                entries: resolvedSourceProfiles.map {
                    BrowserImportExecutionEntry(
                        sourceProfiles: [$0],
                        destination: destinationRequest
                    )
                }
            )
        }

        return separateProfilesPlan(
            selectedSourceProfiles: resolvedSourceProfiles,
            destinationProfiles: destinationProfiles
        )
    }

    static func separateProfilesPlan(
        selectedSourceProfiles: [InstalledBrowserProfile],
        destinationProfiles: [BrowserProfileDefinition]
    ) -> BrowserImportExecutionPlan {
        var reservedNames = Set(destinationProfiles.map { normalizedProfileName($0.displayName) })

        return BrowserImportExecutionPlan(
            mode: .separateProfiles,
            entries: selectedSourceProfiles.map { profile in
                if let matchingProfile = matchingDestinationProfile(
                    for: profile.displayName,
                    destinationProfiles: destinationProfiles
                ) {
                    return BrowserImportExecutionEntry(
                        sourceProfiles: [profile],
                        destination: .existing(matchingProfile.id)
                    )
                }

                let createName = nextCreateName(
                    baseName: profile.displayName,
                    takenNames: reservedNames
                )
                reservedNames.insert(normalizedProfileName(createName))
                return BrowserImportExecutionEntry(
                    sourceProfiles: [profile],
                    destination: .createNamed(createName)
                )
            }
        )
    }

    private static func matchingDestinationProfile(
        for sourceProfileName: String,
        destinationProfiles: [BrowserProfileDefinition]
    ) -> BrowserProfileDefinition? {
        let normalizedSourceName = normalizedProfileName(sourceProfileName)
        guard !normalizedSourceName.isEmpty else { return nil }
        return destinationProfiles.first {
            normalizedProfileName($0.displayName) == normalizedSourceName
        }
    }

    private static func nextCreateName(
        baseName: String,
        takenNames: Set<String>
    ) -> String {
        let trimmedBaseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseName = trimmedBaseName.isEmpty ? "Profile" : trimmedBaseName
        if !takenNames.contains(normalizedProfileName(resolvedBaseName)) {
            return resolvedBaseName
        }

        var suffix = 2
        while true {
            let candidate = "\(resolvedBaseName) (\(suffix))"
            if !takenNames.contains(normalizedProfileName(candidate)) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func normalizedProfileName(_ rawName: String) -> String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @MainActor
    static func realize(
        plan: BrowserImportExecutionPlan,
        profileStore: BrowserProfileStore = .shared
    ) throws -> RealizedBrowserImportExecutionPlan {
        var realizedEntries: [RealizedBrowserImportExecutionEntry] = []
        var createdProfiles: [BrowserProfileDefinition] = []

        for entry in plan.entries {
            let destinationProfile: BrowserProfileDefinition
            switch entry.destination {
            case .existing(let id):
                guard let existingProfile = profileStore.profileDefinition(id: id) else {
                    throw BrowserImportPlanRealizationError.missingDestinationProfile(id)
                }
                destinationProfile = existingProfile
            case .createNamed(let name):
                if let existingProfile = matchingDestinationProfile(
                    for: name,
                    destinationProfiles: profileStore.profiles
                ) {
                    destinationProfile = existingProfile
                } else if let createdProfile = profileStore.createProfile(named: name) {
                    createdProfiles.append(createdProfile)
                    destinationProfile = createdProfile
                } else {
                    throw BrowserImportPlanRealizationError.profileCreationFailed(name)
                }
            }

            realizedEntries.append(
                RealizedBrowserImportExecutionEntry(
                    sourceProfiles: entry.sourceProfiles,
                    destinationProfileID: destinationProfile.id,
                    destinationProfileName: destinationProfile.displayName
                )
            )
        }

        return RealizedBrowserImportExecutionPlan(
            mode: plan.mode,
            entries: realizedEntries,
            createdProfiles: createdProfiles
        )
    }
}

#if canImport(CommonCrypto) && canImport(Security)
private struct ChromiumCookieKeychainItem: Hashable {
    let service: String
    let account: String
}

private final class ChromiumCookieDecryptor {
    private enum KeychainLookupResult {
        case success(Data)
        case failure(OSStatus)
    }

    enum FailureReason {
        case keychain(OSStatus)
        case itemNotFound
        case unreadableSecret
        case decrypt
        case unsupportedFormat
    }

    private let browser: InstalledBrowserCandidate
    private var cachedKeychainItem: ChromiumCookieKeychainItem?
    private var cachedPasswordData: Data?
    private var attemptedLookup = false
    private(set) var lastFailureReason: FailureReason?

    init(browser: InstalledBrowserCandidate) {
        self.browser = browser
    }

    var resolvedKeychainItemName: String? {
        cachedKeychainItem?.service
    }

    func decryptCookieValue(encryptedValue: Data, host: String) -> String? {
        guard let versionPrefix = chromiumVersionPrefix(in: encryptedValue) else {
            lastFailureReason = .unsupportedFormat
            return nil
        }

        guard let passwordData = passwordData() else {
            return nil
        }

        let ciphertext = encryptedValue.dropFirst(versionPrefix.count)
        guard let key = deriveKey(from: passwordData),
              let plaintext = decrypt(ciphertext: Data(ciphertext), key: key),
              let cookieValue = decodePlaintext(plaintext, host: host) else {
            lastFailureReason = .decrypt
            return nil
        }

        lastFailureReason = nil
        return cookieValue
    }

    func warningMessage(browserName: String, skippedCount: Int) -> String? {
        guard skippedCount > 0, let failure = lastFailureReason else { return nil }
        switch failure {
        case .keychain, .itemNotFound, .unreadableSecret:
            let itemName = resolvedKeychainItemName ?? suggestedKeychainItems().first?.service ?? "\(browserName) Storage Key"
            return String(
                format: String(
                    localized: "browser.import.warning.keychainDecryptFailed",
                    defaultValue: "Skipped %ld encrypted %@ cookies because %@ could not be unlocked from Keychain."
                ),
                skippedCount,
                browserName,
                itemName
            )
        case .decrypt, .unsupportedFormat:
            return String(
                format: String(
                    localized: "browser.import.warning.encryptedCookiesSkipped",
                    defaultValue: "Skipped %ld encrypted cookies that require Keychain decryption."
                ),
                skippedCount
            )
        }
    }

    private func passwordData() -> Data? {
        if let cachedPasswordData {
            return cachedPasswordData
        }
        guard !attemptedLookup else {
            return nil
        }
        attemptedLookup = true

        for item in suggestedKeychainItems() {
            switch readPasswordData(item: item) {
            case .success(let passwordData):
                guard !passwordData.isEmpty else {
                    cachedKeychainItem = item
                    lastFailureReason = .unreadableSecret
                    return nil
                }
                cachedKeychainItem = item
                cachedPasswordData = passwordData
                lastFailureReason = nil
                return passwordData
            case .failure(let status):
                if status == errSecItemNotFound {
                    continue
                }
                cachedKeychainItem = item
                lastFailureReason = .keychain(status)
                return nil
            }
        }

        lastFailureReason = .itemNotFound
        return nil
    }

    private func suggestedKeychainItems() -> [ChromiumCookieKeychainItem] {
        var result: [ChromiumCookieKeychainItem] = []
        var seen = Set<ChromiumCookieKeychainItem>()

        func append(service: String, account: String) {
            let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedService.isEmpty, !trimmedAccount.isEmpty else { return }
            let item = ChromiumCookieKeychainItem(service: trimmedService, account: trimmedAccount)
            if seen.insert(item).inserted {
                result.append(item)
            }
        }

        for baseName in keychainBaseNames() {
            append(service: "\(baseName) Storage Key", account: baseName)
            append(service: "\(baseName) Safe Storage", account: baseName)
        }

        for baseName in keychainBaseNames() {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: baseName,
                kSecReturnAttributes: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            var rawResult: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
            guard status == errSecSuccess else { continue }
            let attributesList = rawResult as? [[String: Any]] ?? []
            for attributes in attributesList {
                guard let service = attributes[kSecAttrService as String] as? String else { continue }
                guard service.contains("Storage Key") || service.contains("Safe Storage") else { continue }
                append(service: service, account: baseName)
            }
        }

        return result
    }

    private func keychainBaseNames() -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ rawName: String?) {
            guard let rawName else { return }
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return }
            if seen.insert(trimmedName).inserted {
                result.append(trimmedName)
            }
        }

        append(browser.displayName)
        append(browser.appURL?.deletingPathExtension().lastPathComponent)
        append(browser.descriptor.appNames.first?.replacingOccurrences(of: ".app", with: ""))

        if let appURL = browser.appURL,
           let bundle = Bundle(url: appURL) {
            append(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            append(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        }

        for name in Array(result) {
            if name.hasPrefix("Google ") {
                append(String(name.dropFirst("Google ".count)))
            }
            if name.hasSuffix(" Browser") {
                append(String(name.dropLast(" Browser".count)))
            }
        }

        switch browser.descriptor.id {
        case "google-chrome":
            append("Chrome")
        case "chromium":
            append("Chromium")
        case "brave":
            append("Brave")
        case "helium":
            append("Helium")
        default:
            break
        }

        return result
    }

    private func readPasswordData(item: ChromiumCookieKeychainItem) -> KeychainLookupResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: item.service,
            kSecAttrAccount: item.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
        guard status == errSecSuccess else {
            return .failure(status)
        }
        guard let passwordData = rawResult as? Data else {
            return .failure(errSecDecode)
        }
        return .success(passwordData)
    }

    private func chromiumVersionPrefix(in encryptedValue: Data) -> Data? {
        for prefix in [Data("v10".utf8), Data("v11".utf8)] where encryptedValue.starts(with: prefix) {
            return prefix
        }
        return nil
    }

    private func deriveKey(from passwordData: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: kCCKeySizeAES128)

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        kCCKeySizeAES128
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return derivedKey
    }

    private func decrypt(ciphertext: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var plaintextLength = 0
        let plaintextCapacity = plaintext.count

        let status = plaintext.withUnsafeMutableBytes { plaintextBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            plaintextBytes.baseAddress,
                            plaintextCapacity,
                            &plaintextLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        plaintext.removeSubrange(plaintextLength...)
        return plaintext
    }

    private func decodePlaintext(_ plaintext: Data, host: String) -> String? {
        if let value = String(data: plaintext, encoding: .utf8) {
            return value
        }

        let hostDigest = Data(SHA256.hash(data: Data(host.utf8)))
        if plaintext.starts(with: hostDigest) {
            return String(data: plaintext.dropFirst(hostDigest.count), encoding: .utf8)
        }

        return nil
    }
}
#else
private final class ChromiumCookieDecryptor {
    init(browser: InstalledBrowserCandidate) {}

    func decryptCookieValue(encryptedValue: Data, host: String) -> String? { nil }

    func warningMessage(browserName: String, skippedCount: Int) -> String? {
        guard skippedCount > 0 else { return nil }
        return String(
            format: String(
                localized: "browser.import.warning.encryptedCookiesSkipped",
                defaultValue: "Skipped %ld encrypted cookies that require Keychain decryption."
            ),
            skippedCount
        )
    }
}
#endif

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
        plan: RealizedBrowserImportExecutionPlan,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcome {
        var outcomeEntries: [BrowserImportOutcomeEntry] = []
        var warnings: [String] = []
        var seenWarnings = Set<String>()

        for entry in plan.entries {
            let outcomeEntry = await importEntry(
                from: browser,
                sourceProfiles: entry.sourceProfiles,
                destinationProfileID: entry.destinationProfileID,
                destinationProfileName: entry.destinationProfileName,
                scope: scope,
                domainFilters: domainFilters
            )
            outcomeEntries.append(outcomeEntry)
            for warning in outcomeEntry.warnings where seenWarnings.insert(warning).inserted {
                warnings.append(warning)
            }
        }

        if scope == .everything {
            let unavailableWarning = String(
                localized: "browser.import.warning.additionalDataUnavailable",
                defaultValue: "Bookmarks, settings, and extensions import are not available yet. Imported cookies and history only."
            )
            if seenWarnings.insert(unavailableWarning).inserted {
                warnings.append(unavailableWarning)
            }
        }

        return BrowserImportOutcome(
            browserName: browser.displayName,
            scope: scope,
            domainFilters: domainFilters,
            createdDestinationProfileNames: plan.createdProfiles.map(\.displayName),
            entries: outcomeEntries,
            warnings: warnings
        )
    }

    private static func importEntry(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        destinationProfileName: String,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcomeEntry {
        let resolvedSourceProfiles = sourceProfiles.isEmpty ? browser.profiles : sourceProfiles
        var cookieResult = CookieImportResult()
        if scope.includesCookies {
            cookieResult = await importCookies(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var historyResult = HistoryImportResult()
        if scope.includesHistory {
            historyResult = await importHistory(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var warnings = cookieResult.warnings
        warnings.append(contentsOf: historyResult.warnings)
        return BrowserImportOutcomeEntry(
            sourceProfileNames: resolvedSourceProfiles.map(\.displayName),
            destinationProfileName: destinationProfileName,
            importedCookies: cookieResult.importedCount,
            skippedCookies: cookieResult.skippedCount,
            importedHistoryEntries: historyResult.importedCount,
            warnings: warnings
        )
    }

    private static func importCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxCookies(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .chromium:
            return await importChromiumCookies(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .webkit:
            if browser.descriptor.id == "safari" {
                return CookieImportResult(
                    importedCount: 0,
                    skippedCount: 0,
                    warnings: [
                        String(
                            localized: "browser.import.warning.safariCookiesUnsupported",
                            defaultValue: "Safari cookies are stored in Cookies.binarycookies and are not yet supported by this importer."
                        )
                    ]
                )
            }
            return CookieImportResult(
                importedCount: 0,
                skippedCount: 0,
                warnings: [
                    String(
                        format: String(
                            localized: "browser.import.warning.cookieImportUnsupported",
                            defaultValue: "%@ cookie import is not implemented yet."
                        ),
                        browser.displayName
                    )
                ]
            )
        }
    }

    private static func importHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .chromium:
            return await importChromiumHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .webkit:
            return await importWebKitHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }
    }

    private static func importFirefoxCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("cookies.sqlite", isDirectory: false)
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
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.firefoxCookiesReadFailed",
                            defaultValue: "Failed reading Firefox cookies at %@: %@"
                        ),
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies, destinationProfileID: destinationProfileID)
        return CookieImportResult(importedCount: importedCount, skippedCount: max(0, dedupedCookies.count - importedCount), warnings: warnings)
    }

    private static func importChromiumCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []
        var skippedEncryptedCookies = 0
        let decryptor = ChromiumCookieDecryptor(browser: browser)

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("Cookies", isDirectory: false)
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
                    let encryptedValue = sqliteColumnData(statement, index: 6)

                    guard !name.isEmpty else { return }
                    guard domainMatches(host: host, filters: domainFilters) else { return }

                    var usableValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if usableValue.isEmpty && !encryptedValue.isEmpty {
                        if let decryptedValue = decryptor.decryptCookieValue(
                            encryptedValue: encryptedValue,
                            host: host
                        ) {
                            usableValue = decryptedValue
                        } else {
                            skippedEncryptedCookies += 1
                            return
                        }
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
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserCookiesReadFailed",
                            defaultValue: "Failed reading %@ cookies at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies, destinationProfileID: destinationProfileID)
        if let warning = decryptor.warningMessage(
            browserName: browser.displayName,
            skippedCount: skippedEncryptedCookies
        ) {
            warnings.append(warning)
        }
        let skippedCount = max(0, dedupedCookies.count - importedCount) + skippedEncryptedCookies
        return CookieImportResult(importedCount: importedCount, skippedCount: skippedCount, warnings: warnings)
    }

    private static func importFirefoxHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("places.sqlite", isDirectory: false)
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
                    let lastVisited = firefoxDate(fromUnixMicroseconds: lastVisitMicros) ?? .distantPast
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.firefoxHistoryReadFailed",
                            defaultValue: "Failed reading Firefox history at %@: %@"
                        ),
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importChromiumHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("History", isDirectory: false)
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
                    let lastVisited = chromiumDate(fromWebKitMicroseconds: lastVisitMicros) ?? .distantPast
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserHistoryReadFailed",
                            defaultValue: "Failed reading %@ history at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importWebKitHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        var candidateDatabaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("History.db", isDirectory: false)
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
            return HistoryImportResult(
                importedCount: 0,
                warnings: [
                    String(
                        format: String(
                            localized: "browser.import.warning.noHistoryDatabase",
                            defaultValue: "No history database found for %@."
                        ),
                        browser.displayName
                    )
                ]
            )
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
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserHistoryReadFailed",
                            defaultValue: "Failed reading %@ history at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func mergeHistoryRows(_ rows: [HistoryRow], destinationProfileID: UUID) async -> Int {
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
            let historyStore = BrowserProfileStore.shared.historyStore(for: destinationProfileID)
            return historyStore.mergeImportedEntries(entries)
        }
    }

    private static func setCookiesInStore(_ cookies: [HTTPCookie], destinationProfileID: UUID) async -> Int {
        guard !cookies.isEmpty else { return 0 }
        let store = await MainActor.run {
            BrowserProfileStore.shared.websiteDataStore(for: destinationProfileID).httpCookieStore
        }
        var importedCount = 0
        for cookie in cookies {
            await setCookie(cookie, in: store)
            importedCount += 1
        }
        return importedCount
    }

    @MainActor
    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
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

    private static func sqliteColumnData(_ statement: OpaquePointer, index: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: pointer, count: length)
    }
}

#if DEBUG
enum BrowserImportUITestFixtureLoader {
    private struct BrowserFixture: Decodable {
        let browserName: String
        let profiles: [String]
    }

    static func browsers(from environment: [String: String]) -> [InstalledBrowserCandidate]? {
        guard let rawFixture = environment["CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE"],
              let data = rawFixture.data(using: .utf8),
              let fixture = try? JSONDecoder().decode(BrowserFixture.self, from: data) else {
            return nil
        }

        let resolvedProfiles = fixture.profiles.enumerated().map { index, name in
            InstalledBrowserProfile(
                displayName: name,
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-ui-test-browser-import")
                    .appendingPathComponent(
                        fixture.browserName
                            .lowercased()
                            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                    )
                    .appendingPathComponent("\(index)-\(name)")
                    .standardizedFileURL,
                isDefault: index == 0
            )
        }

        let descriptor = InstalledBrowserDetector.allBrowserDescriptors.first(where: {
            $0.displayName == fixture.browserName
        }) ?? BrowserImportBrowserDescriptor(
            id: fixture.browserName
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            displayName: fixture.browserName,
            family: .chromium,
            tier: 0,
            bundleIdentifiers: [],
            appNames: [],
            dataRootRelativePaths: [],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: false
        )

        return [
            InstalledBrowserCandidate(
                descriptor: descriptor,
                resolvedFamily: descriptor.family,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                appURL: nil,
                dataRootURL: nil,
                profiles: resolvedProfiles,
                detectionSignals: ["ui-test-fixture"],
                detectionScore: Int.max
            )
        ]
    }

    static func destinationProfiles(from environment: [String: String]) -> [BrowserProfileDefinition]? {
        guard let rawDestinations = environment["CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS"],
              let data = rawDestinations.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data),
              !names.isEmpty else {
            return nil
        }

        return names.enumerated().map { index, rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.localizedCaseInsensitiveCompare("Default") == .orderedSame {
                return BrowserProfileDefinition(
                    id: UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!,
                    displayName: "Default",
                    createdAt: .distantPast,
                    isBuiltInDefault: true
                )
            }
            return BrowserProfileDefinition(
                id: UUID(),
                displayName: name.isEmpty ? "Profile \(index + 1)" : name,
                createdAt: .distantPast,
                isBuiltInDefault: false
            )
        }
    }
}
#endif

@MainActor
final class BrowserDataImportCoordinator {
    static let shared = BrowserDataImportCoordinator()

    private var importInProgress = false

    private init() {}

    func presentImportDialog(defaultDestinationProfileID: UUID? = nil) {
        presentImportDialog(prefilledBrowsers: nil, defaultDestinationProfileID: defaultDestinationProfileID)
    }

    private struct ImportSelection {
        let browser: InstalledBrowserCandidate
        let executionPlan: BrowserImportExecutionPlan
        let scope: BrowserImportScope
        let domainFilters: [String]
    }

    private func presentImportDialog(
        prefilledBrowsers: [InstalledBrowserCandidate]?,
        defaultDestinationProfileID: UUID?
    ) {
        guard !importInProgress else { return }
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let fixtureBrowsers = BrowserImportUITestFixtureLoader.browsers(from: environment)
        let fixtureDestinationProfiles = BrowserImportUITestFixtureLoader.destinationProfiles(from: environment)
        let browsers = prefilledBrowsers ?? fixtureBrowsers ?? InstalledBrowserDetector.detectInstalledBrowsers()
#else
        let fixtureDestinationProfiles: [BrowserProfileDefinition]? = nil
        let browsers = prefilledBrowsers ?? InstalledBrowserDetector.detectInstalledBrowsers()
#endif
        guard !browsers.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.noBrowsers.title",
                defaultValue: "No importable browsers found"
            )
            alert.informativeText = String(
                localized: "browser.import.noBrowsers.message",
                defaultValue: "cmux could not find browser profiles to import from on this Mac."
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }

        guard let selection = promptForSelection(
            browsers: browsers,
            destinationProfiles: fixtureDestinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID
        ) else { return }

#if DEBUG
        if captureSelectionIfRequested(selection, destinationProfiles: fixtureDestinationProfiles) {
            return
        }
#endif
        let realizedPlan: RealizedBrowserImportExecutionPlan
        do {
            realizedPlan = try BrowserImportPlanResolver.realize(plan: selection.executionPlan)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.error.title",
                defaultValue: "Import could not start"
            )
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }
        importInProgress = true

        let progressWindow = showProgressWindow(
            title: String(
                localized: "browser.import.progress.title",
                defaultValue: "Importing Browser Data"
            ),
            message: String(
                format: String(
                    localized: "browser.import.progress.message",
                    defaultValue: "Importing %@ from %@…"
                ),
                selection.scope.displayName.lowercased(),
                selection.browser.displayName
            )
        )

        Task.detached(priority: .userInitiated) {
            let outcome = await BrowserDataImporter.importData(
                from: selection.browser,
                plan: realizedPlan,
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

    private func promptForSelection(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]?,
        defaultDestinationProfileID: UUID?
    ) -> ImportSelection? {
        guard !browsers.isEmpty else { return nil }
        let wizard = ImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID
        )
        return wizard.runModal()
    }

#if DEBUG
    func debugMakeImportWizardWindow(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]? = nil,
        defaultDestinationProfileID: UUID? = nil
    ) -> NSWindow {
        let wizard = ImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID
        )
        return wizard.debugPanelWindow
    }
#endif

#if DEBUG
    private struct CapturedImportSelection: Encodable {
        struct Entry: Encodable {
            let sourceProfiles: [String]
            let destinationKind: String
            let destinationName: String
        }

        let browserName: String
        let mode: String
        let scope: String
        let domainFilters: [String]
        let entries: [Entry]
    }

    private func captureSelectionIfRequested(
        _ selection: ImportSelection,
        destinationProfiles: [BrowserProfileDefinition]?
    ) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_BROWSER_IMPORT_MODE"] == "capture-only" else { return false }
        guard let path = environment["CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH"], !path.isEmpty else {
            return true
        }

        let availableDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
        let payload = CapturedImportSelection(
            browserName: selection.browser.displayName,
            mode: captureModeName(selection.executionPlan.mode),
            scope: selection.scope.rawValue,
            domainFilters: selection.domainFilters,
            entries: selection.executionPlan.entries.map { entry in
                let destinationKind: String
                let destinationName: String
                switch entry.destination {
                case .existing(let id):
                    destinationKind = "existing"
                    destinationName = availableDestinationProfiles.first(where: { $0.id == id })?.displayName
                        ?? BrowserProfileStore.shared.displayName(for: id)
                case .createNamed(let name):
                    destinationKind = "create"
                    destinationName = name
                }
                return CapturedImportSelection.Entry(
                    sourceProfiles: entry.sourceProfiles.map(\.displayName),
                    destinationKind: destinationKind,
                    destinationName: destinationName
                )
            }
        )

        guard let data = try? JSONEncoder().encode(payload) else { return true }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? data.write(to: url)
        return true
    }

    private func captureModeName(_ mode: BrowserImportDestinationMode) -> String {
        switch mode {
        case .singleDestination:
            return "singleDestination"
        case .separateProfiles:
            return "separateProfiles"
        case .mergeIntoOne:
            return "mergeIntoOne"
        }
    }
#endif

    @MainActor
    private final class ImportWizardWindowController: NSObject, @preconcurrency NSWindowDelegate {
        private final class FlippedDocumentView: NSView {
            override var isFlipped: Bool { true }
        }

        private enum Step {
            case source
            case sourceProfiles
            case dataTypes
        }

        private let browsers: [InstalledBrowserCandidate]
        private let destinationProfiles: [BrowserProfileDefinition]
        private let initialDestinationProfileID: UUID

        private var step: Step = .source
        private var didFinishModal = false
        private(set) var selection: ImportSelection?
        private var selectedSourceProfileIDsByBrowserID: [String: Set<String>] = [:]
        private var sourceProfileCheckboxes: [NSButton] = []
        private var destinationMode: BrowserImportDestinationMode = .singleDestination
        private var separateExecutionEntries: [BrowserImportExecutionEntry] = []
        private var separateDestinationOptionsByEntryIndex: [Int: [BrowserImportDestinationRequest]] = [:]
        private var mergeDestinationProfileID: UUID

        private let panel: NSPanel

        private let stepLabel = NSTextField(labelWithString: "")
        private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        private let sourceContainer = NSStackView()
        private let sourceProfilesContainer = NSStackView()
        private let sourceProfilesList = NSStackView()
        private let sourceProfilesDocumentView = FlippedDocumentView(frame: .zero)
        private let sourceProfilesEmptyLabel = NSTextField(wrappingLabelWithString: "")
        private let sourceProfilesHelpLabel = NSTextField(labelWithString: "")
        private let sourceProfilesScrollView = NSScrollView()
        private var sourceProfilesScrollHeightConstraint: NSLayoutConstraint?
        private let dataTypesContainer = NSStackView()
        private let validationLabel = NSTextField(labelWithString: "")
        private let destinationModeContainer = NSStackView()
        private let separateProfilesRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
        private let mergeProfilesRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
        private let separateDestinationRows = NSStackView()
        private let mergeDestinationRow = NSStackView()
        private let mergeDestinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        private let destinationHelpLabel = NSTextField(wrappingLabelWithString: "")
        private let additionalDataNoteLabel = NSTextField(wrappingLabelWithString: "")

        private let cookiesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        private let historyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        private let additionalDataCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        private let domainField = NSTextField(frame: .zero)

        private let backButton = NSButton(title: "", target: nil, action: nil)
        private let cancelButton = NSButton(title: "", target: nil, action: nil)
        private let primaryButton = NSButton(title: "", target: nil, action: nil)

        init(
            browsers: [InstalledBrowserCandidate],
            destinationProfiles: [BrowserProfileDefinition]?,
            defaultDestinationProfileID: UUID?
        ) {
            let resolvedDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
            let fallbackDestinationProfileID = resolvedDestinationProfiles.first?.id
                ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
            self.browsers = browsers
            self.destinationProfiles = resolvedDestinationProfiles
            self.initialDestinationProfileID = defaultDestinationProfileID
                .flatMap { candidateID in resolvedDestinationProfiles.first(where: { $0.id == candidateID })?.id }
                ?? fallbackDestinationProfileID
            self.mergeDestinationProfileID = self.initialDestinationProfileID
            self.panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 292),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            super.init()
            setupUI()
            configureInitialState()
        }

        func runModal() -> ImportSelection? {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            let response = NSApp.runModal(for: panel)
            if panel.isVisible {
                panel.orderOut(nil)
            }

            guard response == .OK else { return nil }
            return selection
        }

#if DEBUG
        var debugPanelWindow: NSWindow { panel }
#endif

        func windowWillClose(_ notification: Notification) {
            finishModal(with: .cancel)
        }

        @objc
        private func handleBack() {
            switch step {
            case .source:
                return
            case .sourceProfiles:
                step = .source
            case .dataTypes:
                step = .sourceProfiles
            }
            validationLabel.isHidden = true
            updateStepUI()
        }

        @objc
        private func handleCancel() {
            finishModal(with: .cancel)
        }

        @objc
        private func handlePrimary() {
            switch step {
            case .source:
                step = .sourceProfiles
                validationLabel.isHidden = true
                refreshSourceProfilesList()
                updateStepUI()
            case .sourceProfiles:
                let selectedSourceProfiles = selectedSourceProfiles()
                guard !selectedSourceProfiles.isEmpty else {
                    validationLabel.stringValue = String(
                        localized: "browser.import.validation.sourceProfiles",
                        defaultValue: "Choose at least one source profile to import."
                    )
                    validationLabel.isHidden = false
                    return
                }

                resetStep3State()
                step = .dataTypes
                validationLabel.isHidden = true
                updateStepUI()
            case .dataTypes:
                let includeCookies = cookiesCheckbox.state == .on
                let includeHistory = historyCheckbox.state == .on
                let includeAdditionalData = additionalDataCheckbox.state == .on
                guard let scope = BrowserImportScope.fromSelection(
                    includeCookies: includeCookies,
                    includeHistory: includeHistory,
                    includeAdditionalData: includeAdditionalData
                ) else {
                    validationLabel.stringValue = String(
                        localized: "browser.import.validation.scope",
                        defaultValue: "Select Cookies, History, or both before starting import."
                    )
                    validationLabel.isHidden = false
                    return
                }

                let selectedBrowser = selectedBrowser()
                let domainFilters = BrowserDataImporter.parseDomainFilters(domainField.stringValue)
                selection = ImportSelection(
                    browser: selectedBrowser,
                    executionPlan: currentExecutionPlan(),
                    scope: scope,
                    domainFilters: domainFilters
                )
                finishModal(with: .OK)
            }
        }

        @objc
        private func handleSourceChanged() {
            validationLabel.isHidden = true
            refreshSourceProfilesList()
            updateStepUI()
        }

        @objc
        private func handleSourceProfileToggled(_ sender: NSButton) {
            guard let profileID = sender.identifier?.rawValue else { return }
            let browserID = selectedBrowser().id
            var selectedIDs = storedSelectedSourceProfileIDs(for: selectedBrowser())
            if sender.state == .on {
                selectedIDs.insert(profileID)
            } else {
                selectedIDs.remove(profileID)
            }
            selectedSourceProfileIDsByBrowserID[browserID] = selectedIDs
            validationLabel.isHidden = true
        }

        @objc
        private func handleDestinationModeChanged(_ sender: NSButton) {
            let selectedSourceProfiles = selectedSourceProfiles()
            guard selectedSourceProfiles.count > 1 else { return }
            destinationMode = sender == separateProfilesRadio ? .separateProfiles : .mergeIntoOne
            rebuildStep3DestinationUI()
            updatePanelSize()
        }

        @objc
        private func handleMergeDestinationChanged(_ sender: NSPopUpButton) {
            let selectedIndex = max(0, min(sender.indexOfSelectedItem, destinationProfiles.count - 1))
            guard destinationProfiles.indices.contains(selectedIndex) else { return }
            mergeDestinationProfileID = destinationProfiles[selectedIndex].id
            validationLabel.isHidden = true
        }

        @objc
        private func handleSeparateDestinationChanged(_ sender: NSPopUpButton) {
            let entryIndex = sender.tag
            guard separateExecutionEntries.indices.contains(entryIndex),
                  let options = separateDestinationOptionsByEntryIndex[entryIndex],
                  options.indices.contains(sender.indexOfSelectedItem) else {
                return
            }
            separateExecutionEntries[entryIndex].destination = options[sender.indexOfSelectedItem]
            validationLabel.isHidden = true
        }

        @objc
        private func handleImportOptionChanged(_ sender: NSButton) {
            validationLabel.isHidden = true
            updateAdditionalDataNoteVisibility()
            updatePanelSize()
        }

        private func setupUI() {
            panel.title = String(
                localized: "browser.import.title",
                defaultValue: "Import Browser Data"
            )
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 292))
            contentView.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView = contentView

            let titleLabel = NSTextField(
                labelWithString: String(
                    localized: "browser.import.title",
                    defaultValue: "Import Browser Data"
                )
            )
            titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

            stepLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            stepLabel.textColor = .secondaryLabelColor

            setupSourceContainer()
            setupSourceProfilesContainer()
            setupDataTypesContainer()

            validationLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            validationLabel.textColor = .systemRed
            validationLabel.isHidden = true
            validationLabel.lineBreakMode = .byWordWrapping
            validationLabel.maximumNumberOfLines = 3
            validationLabel.translatesAutoresizingMaskIntoConstraints = false

            backButton.target = self
            backButton.action = #selector(handleBack)
            backButton.bezelStyle = .rounded
            backButton.title = String(localized: "browser.import.back", defaultValue: "Back")

            cancelButton.target = self
            cancelButton.action = #selector(handleCancel)
            cancelButton.bezelStyle = .rounded
            cancelButton.title = String(localized: "common.cancel", defaultValue: "Cancel")
            cancelButton.keyEquivalent = "\u{1b}"

            primaryButton.target = self
            primaryButton.action = #selector(handlePrimary)
            primaryButton.bezelStyle = .rounded
            primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next")
            primaryButton.keyEquivalent = "\r"

            let buttonSpacer = NSView(frame: .zero)

            let buttonRow = NSStackView(views: [buttonSpacer, backButton, cancelButton, primaryButton])
            buttonRow.orientation = .horizontal
            buttonRow.spacing = 8
            buttonRow.alignment = .centerY
            buttonRow.translatesAutoresizingMaskIntoConstraints = false
            buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            buttonSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let contentStack = NSStackView(views: [
                titleLabel,
                stepLabel,
                sourceContainer,
                sourceProfilesContainer,
                dataTypesContainer,
                validationLabel,
            ])
            contentStack.orientation = .vertical
            contentStack.spacing = 8
            contentStack.alignment = .leading
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            sourceContainer.translatesAutoresizingMaskIntoConstraints = false
            sourceProfilesContainer.translatesAutoresizingMaskIntoConstraints = false
            dataTypesContainer.translatesAutoresizingMaskIntoConstraints = false

            guard let panelContent = panel.contentView else { return }
            panelContent.addSubview(contentStack)
            panelContent.addSubview(buttonRow)

            NSLayoutConstraint.activate([
                contentStack.topAnchor.constraint(equalTo: panelContent.topAnchor, constant: 16),
                contentStack.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 18),
                contentStack.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -18),

                buttonRow.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 14),
                buttonRow.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 18),
                buttonRow.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -18),
                buttonRow.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor, constant: -14),

                sourceContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
                sourceProfilesContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
                dataTypesContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
                validationLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            ])
        }

        private func setupSourceContainer() {
            for browser in browsers {
                sourcePopup.addItem(withTitle: browser.displayName)
            }
            sourcePopup.selectItem(at: 0)
            sourcePopup.target = self
            sourcePopup.action = #selector(handleSourceChanged)

            let sourceLabel = NSTextField(
                labelWithString: String(localized: "browser.import.source", defaultValue: "Source")
            )
            sourceLabel.alignment = .right
            sourceLabel.frame.size.width = 64

            sourcePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            sourcePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let sourceRow = NSStackView(views: [sourceLabel, sourcePopup])
            sourceRow.orientation = .horizontal
            sourceRow.spacing = 8
            sourceRow.alignment = .centerY
            sourceRow.distribution = .fill

            let detectedLabel = NSTextField(
                wrappingLabelWithString: InstalledBrowserDetector.summaryText(for: browsers)
            )
            detectedLabel.font = NSFont.systemFont(ofSize: 11)
            detectedLabel.textColor = .secondaryLabelColor
            detectedLabel.maximumNumberOfLines = 2
            detectedLabel.preferredMaxLayoutWidth = 500

            sourceContainer.orientation = .vertical
            sourceContainer.spacing = 8
            sourceContainer.alignment = .leading
            sourceContainer.addArrangedSubview(sourceRow)
            sourceContainer.addArrangedSubview(detectedLabel)
        }

        private func setupSourceProfilesContainer() {
            let sourceProfilesTitle = NSTextField(
                labelWithString: String(
                    localized: "browser.import.sourceProfiles",
                    defaultValue: "Source Profiles"
                )
            )
            sourceProfilesTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

            sourceProfilesList.orientation = .vertical
            sourceProfilesList.spacing = 6
            sourceProfilesList.alignment = .leading
            sourceProfilesList.translatesAutoresizingMaskIntoConstraints = false

            sourceProfilesEmptyLabel.font = NSFont.systemFont(ofSize: 12)
            sourceProfilesEmptyLabel.textColor = .secondaryLabelColor
            sourceProfilesEmptyLabel.maximumNumberOfLines = 0
            sourceProfilesEmptyLabel.preferredMaxLayoutWidth = 500

            sourceProfilesDocumentView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            sourceProfilesDocumentView.translatesAutoresizingMaskIntoConstraints = false
            sourceProfilesDocumentView.addSubview(sourceProfilesList)
            NSLayoutConstraint.activate([
                sourceProfilesList.topAnchor.constraint(equalTo: sourceProfilesDocumentView.topAnchor),
                sourceProfilesList.leadingAnchor.constraint(equalTo: sourceProfilesDocumentView.leadingAnchor),
                sourceProfilesList.trailingAnchor.constraint(equalTo: sourceProfilesDocumentView.trailingAnchor),
                sourceProfilesList.bottomAnchor.constraint(equalTo: sourceProfilesDocumentView.bottomAnchor),
                sourceProfilesList.widthAnchor.constraint(equalTo: sourceProfilesDocumentView.widthAnchor),
            ])

            sourceProfilesScrollView.drawsBackground = false
            sourceProfilesScrollView.borderType = .bezelBorder
            sourceProfilesScrollView.hasVerticalScroller = true
            sourceProfilesScrollView.documentView = sourceProfilesDocumentView
            sourceProfilesScrollView.translatesAutoresizingMaskIntoConstraints = false
            sourceProfilesScrollView.contentView.postsBoundsChangedNotifications = true
            sourceProfilesScrollHeightConstraint = sourceProfilesScrollView.heightAnchor.constraint(equalToConstant: 76)
            sourceProfilesScrollHeightConstraint?.isActive = true
            let sourceProfilesScrollWidthConstraint = sourceProfilesScrollView.widthAnchor.constraint(
                equalTo: sourceProfilesContainer.widthAnchor
            )

            sourceProfilesHelpLabel.font = NSFont.systemFont(ofSize: 11)
            sourceProfilesHelpLabel.textColor = .secondaryLabelColor
            sourceProfilesHelpLabel.maximumNumberOfLines = 2
            sourceProfilesHelpLabel.lineBreakMode = .byWordWrapping
            sourceProfilesHelpLabel.preferredMaxLayoutWidth = 500
            sourceProfilesHelpLabel.stringValue = String(
                localized: "browser.import.sourceProfiles.help",
                defaultValue: "Choose one or more source profiles. Step 3 lets you keep them separate or merge them into one cmux profile."
            )

            sourceProfilesContainer.orientation = .vertical
            sourceProfilesContainer.spacing = 8
            sourceProfilesContainer.alignment = .leading
            sourceProfilesContainer.addArrangedSubview(sourceProfilesTitle)
            sourceProfilesContainer.addArrangedSubview(sourceProfilesScrollView)
            sourceProfilesContainer.addArrangedSubview(sourceProfilesHelpLabel)
            sourceProfilesScrollWidthConstraint.isActive = true
            sourceProfilesContainer.setHuggingPriority(.defaultLow, for: .vertical)
            sourceProfilesContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        private func setupDataTypesContainer() {
            cookiesCheckbox.state = .on
            historyCheckbox.state = .on
            additionalDataCheckbox.state = .off
            cookiesCheckbox.title = String(
                localized: "browser.import.cookies",
                defaultValue: "Cookies (site sign-ins)"
            )
            historyCheckbox.title = String(
                localized: "browser.import.history",
                defaultValue: "History (visited pages)"
            )
            additionalDataCheckbox.title = String(
                localized: "browser.import.additionalData",
                defaultValue: "Additional data (bookmarks, settings, extensions)"
            )
            cookiesCheckbox.target = self
            cookiesCheckbox.action = #selector(handleImportOptionChanged(_:))
            historyCheckbox.target = self
            historyCheckbox.action = #selector(handleImportOptionChanged(_:))
            additionalDataCheckbox.target = self
            additionalDataCheckbox.action = #selector(handleImportOptionChanged(_:))
            cookiesCheckbox.setAccessibilityIdentifier("BrowserImportCookiesCheckbox")
            historyCheckbox.setAccessibilityIdentifier("BrowserImportHistoryCheckbox")
            additionalDataCheckbox.setAccessibilityIdentifier("BrowserImportAdditionalDataCheckbox")
            separateProfilesRadio.title = String(
                localized: "browser.import.destinationMode.separate",
                defaultValue: "Keep profiles separate"
            )
            mergeProfilesRadio.title = String(
                localized: "browser.import.destinationMode.merge",
                defaultValue: "Merge all into one cmux profile"
            )
            separateProfilesRadio.target = self
            separateProfilesRadio.action = #selector(handleDestinationModeChanged(_:))
            mergeProfilesRadio.target = self
            mergeProfilesRadio.action = #selector(handleDestinationModeChanged(_:))

            destinationModeContainer.orientation = .vertical
            destinationModeContainer.spacing = 6
            destinationModeContainer.alignment = .leading
            destinationModeContainer.addArrangedSubview(separateProfilesRadio)
            destinationModeContainer.addArrangedSubview(mergeProfilesRadio)

            mergeDestinationPopup.target = self
            mergeDestinationPopup.action = #selector(handleMergeDestinationChanged(_:))
            mergeDestinationPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            mergeDestinationPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            separateDestinationRows.orientation = .vertical
            separateDestinationRows.spacing = 6
            separateDestinationRows.alignment = .leading

            mergeDestinationRow.orientation = .horizontal
            mergeDestinationRow.spacing = 6
            mergeDestinationRow.alignment = .centerY

            destinationHelpLabel.font = NSFont.systemFont(ofSize: 11)
            destinationHelpLabel.textColor = .secondaryLabelColor
            destinationHelpLabel.maximumNumberOfLines = 2
            destinationHelpLabel.preferredMaxLayoutWidth = 500

            domainField.placeholderString = String(
                localized: "browser.import.domain.placeholder",
                defaultValue: "Optional domains only (e.g. github.com, openai.com)"
            )
            domainField.stringValue = ""
            domainField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            domainField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let destinationTitleLabel = NSTextField(
                labelWithString: String(
                    localized: "browser.import.destination.cmux",
                    defaultValue: "cmux destination"
                )
            )
            destinationTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

            let domainLabel = NSTextField(
                labelWithString: String(localized: "browser.import.domain", defaultValue: "Limit to")
            )
            domainLabel.alignment = .right
            domainLabel.frame.size.width = 72

            let domainRow = NSStackView(views: [domainLabel, domainField])
            domainRow.orientation = .horizontal
            domainRow.spacing = 8
            domainRow.alignment = .centerY
            domainRow.distribution = .fill

            additionalDataNoteLabel.stringValue = String(
                localized: "browser.import.additionalData.note",
                defaultValue: "Bookmarks, settings, and extensions import are not available yet."
            )
            additionalDataNoteLabel.font = NSFont.systemFont(ofSize: 11)
            additionalDataNoteLabel.textColor = .secondaryLabelColor
            additionalDataNoteLabel.maximumNumberOfLines = 2
            additionalDataNoteLabel.preferredMaxLayoutWidth = 500
            additionalDataNoteLabel.isHidden = true

            dataTypesContainer.orientation = .vertical
            dataTypesContainer.spacing = 6
            dataTypesContainer.alignment = .leading
            dataTypesContainer.addArrangedSubview(destinationTitleLabel)
            dataTypesContainer.addArrangedSubview(destinationModeContainer)
            dataTypesContainer.addArrangedSubview(separateDestinationRows)
            dataTypesContainer.addArrangedSubview(mergeDestinationRow)
            dataTypesContainer.addArrangedSubview(destinationHelpLabel)
            dataTypesContainer.addArrangedSubview(cookiesCheckbox)
            dataTypesContainer.addArrangedSubview(historyCheckbox)
            dataTypesContainer.addArrangedSubview(additionalDataCheckbox)
            dataTypesContainer.addArrangedSubview(additionalDataNoteLabel)
            dataTypesContainer.addArrangedSubview(domainRow)
        }

        private func configureInitialState() {
            step = .source
            refreshSourceProfilesList()
            updateAdditionalDataNoteVisibility()
            updateStepUI()
        }

        private func updateStepUI() {
            switch step {
            case .source:
                stepLabel.stringValue = String(
                    localized: "browser.import.step.source",
                    defaultValue: "Step 1 of 3"
                )
                sourceContainer.isHidden = false
                sourceProfilesContainer.isHidden = true
                dataTypesContainer.isHidden = true
                backButton.isHidden = true
                primaryButton.isEnabled = true
                primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next")
            case .sourceProfiles:
                stepLabel.stringValue = String(
                    localized: "browser.import.step.sourceProfiles",
                    defaultValue: "Step 2 of 3"
                )
                sourceContainer.isHidden = true
                sourceProfilesContainer.isHidden = false
                dataTypesContainer.isHidden = true
                backButton.isHidden = false
                primaryButton.isEnabled = !selectedBrowser().profiles.isEmpty
                primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next")
            case .dataTypes:
                rebuildStep3DestinationUI()
                stepLabel.stringValue = String(
                    localized: "browser.import.step.dataTypes",
                    defaultValue: "Step 3 of 3"
                )
                sourceContainer.isHidden = true
                sourceProfilesContainer.isHidden = true
                dataTypesContainer.isHidden = false
                backButton.isHidden = false
                primaryButton.isEnabled = true
                primaryButton.title = String(
                    localized: "browser.import.start",
                    defaultValue: "Start Import"
                )
            }
            updatePanelSize()
        }

        private func selectedBrowser() -> InstalledBrowserCandidate {
            let selectedIndex = max(0, min(sourcePopup.indexOfSelectedItem, browsers.count - 1))
            return browsers[selectedIndex]
        }

        private func refreshSourceProfilesList() {
            let browser = selectedBrowser()
            let selectedIDs = storedSelectedSourceProfileIDs(for: browser)

            sourceProfileCheckboxes.removeAll()
            for arrangedSubview in sourceProfilesList.arrangedSubviews {
                sourceProfilesList.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            if browser.profiles.isEmpty {
                sourceProfilesEmptyLabel.stringValue = String(
                    format: String(
                        localized: "browser.import.sourceProfiles.empty",
                        defaultValue: "No source profiles detected for %@."
                    ),
                    browser.displayName
                )
                sourceProfilesList.addArrangedSubview(sourceProfilesEmptyLabel)
                updateSourceProfilesPresentation(for: browser)
                return
            }

            for profile in browser.profiles {
                let checkbox = NSButton(
                    checkboxWithTitle: profile.displayName,
                    target: self,
                    action: #selector(handleSourceProfileToggled(_:))
                )
                checkbox.identifier = NSUserInterfaceItemIdentifier(profile.id)
                checkbox.state = selectedIDs.contains(profile.id) ? .on : .off
                checkbox.lineBreakMode = .byTruncatingTail
                sourceProfilesList.addArrangedSubview(checkbox)
                sourceProfileCheckboxes.append(checkbox)
            }

            updateSourceProfilesPresentation(for: browser)
        }

        private func storedSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
            if let existing = selectedSourceProfileIDsByBrowserID[browser.id] {
                return existing
            }
            let defaultSelection = defaultSelectedSourceProfileIDs(for: browser)
            selectedSourceProfileIDsByBrowserID[browser.id] = defaultSelection
            return defaultSelection
        }

        private func defaultSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
            if let defaultProfile = browser.profiles.first(where: \.isDefault) {
                return [defaultProfile.id]
            }
            if let firstProfile = browser.profiles.first {
                return [firstProfile.id]
            }
            return []
        }

        private func selectedSourceProfiles() -> [InstalledBrowserProfile] {
            let browser = selectedBrowser()
            let selectedIDs = storedSelectedSourceProfileIDs(for: browser)
            return browser.profiles.filter { selectedIDs.contains($0.id) }
        }

        private func resetStep3State() {
            let selectedProfiles = selectedSourceProfiles()
            let defaultPlan = BrowserImportPlanResolver.defaultPlan(
                selectedSourceProfiles: selectedProfiles,
                destinationProfiles: destinationProfiles,
                preferredSingleDestinationProfileID: initialDestinationProfileID
            )
            destinationMode = defaultPlan.mode
            separateExecutionEntries = BrowserImportPlanResolver.separateProfilesPlan(
                selectedSourceProfiles: selectedProfiles,
                destinationProfiles: destinationProfiles
            ).entries
            if let initialDestination = defaultPlan.entries.first.flatMap(destinationProfileID(for:)) {
                mergeDestinationProfileID = initialDestination
            } else {
                mergeDestinationProfileID = initialDestinationProfileID
            }
            rebuildStep3DestinationUI()
        }

        private func currentExecutionPlan() -> BrowserImportExecutionPlan {
            let selectedProfiles = selectedSourceProfiles()
            guard !selectedProfiles.isEmpty else {
                return BrowserImportExecutionPlan(mode: .singleDestination, entries: [])
            }

            guard selectedProfiles.count > 1 else {
                return BrowserImportExecutionPlan(
                    mode: .singleDestination,
                    entries: [
                        BrowserImportExecutionEntry(
                            sourceProfiles: selectedProfiles,
                            destination: .existing(resolvedMergeDestinationProfileID())
                        )
                    ]
                )
            }

            switch destinationMode {
            case .separateProfiles:
                let entriesBySourceID = Dictionary(
                    uniqueKeysWithValues: separateExecutionEntries.compactMap { entry in
                        entry.sourceProfiles.first.map { ($0.id, entry.destination) }
                    }
                )
                let entries = selectedProfiles.map { profile in
                    BrowserImportExecutionEntry(
                        sourceProfiles: [profile],
                        destination: entriesBySourceID[profile.id] ?? defaultSeparateDestinationRequest(for: profile)
                    )
                }
                return BrowserImportExecutionPlan(mode: .separateProfiles, entries: entries)
            case .singleDestination, .mergeIntoOne:
                return BrowserImportExecutionPlan(
                    mode: .mergeIntoOne,
                    entries: [
                        BrowserImportExecutionEntry(
                            sourceProfiles: selectedProfiles,
                            destination: .existing(resolvedMergeDestinationProfileID())
                        )
                    ]
                )
            }
        }

        private func rebuildStep3DestinationUI() {
            let plan = currentExecutionPlan()
            let presentation = BrowserImportStep3Presentation(plan: plan)
            destinationModeContainer.isHidden = !presentation.showsModeSelector
            separateDestinationRows.isHidden = !presentation.showsSeparateRows
            mergeDestinationRow.isHidden = !presentation.showsSingleDestinationPicker

            if presentation.showsModeSelector {
                separateProfilesRadio.state = destinationMode == .separateProfiles ? .on : .off
                mergeProfilesRadio.state = destinationMode == .mergeIntoOne ? .on : .off
            } else {
                separateProfilesRadio.state = .off
                mergeProfilesRadio.state = .off
            }

            rebuildSeparateDestinationRows(with: plan)
            rebuildMergeDestinationRow()

            if presentation.showsSeparateRows {
                destinationHelpLabel.stringValue = String(
                    localized: "browser.import.destinationProfile.separateHelp",
                    defaultValue: "Missing cmux profiles are created when import starts."
                )
                destinationHelpLabel.isHidden = false
            } else if plan.entries.count > 1 {
                destinationHelpLabel.stringValue = String(
                    localized: "browser.import.destinationProfile.mergeHelp",
                    defaultValue: "All selected source profiles will be merged into the chosen cmux browser profile."
                )
                destinationHelpLabel.isHidden = false
            } else {
                destinationHelpLabel.stringValue = ""
                destinationHelpLabel.isHidden = true
            }
        }

        private func rebuildSeparateDestinationRows(with plan: BrowserImportExecutionPlan) {
            separateDestinationOptionsByEntryIndex.removeAll()
            for arrangedSubview in separateDestinationRows.arrangedSubviews {
                separateDestinationRows.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            guard plan.mode == .separateProfiles else { return }

            for (index, entry) in plan.entries.enumerated() {
                guard let sourceProfile = entry.sourceProfiles.first else { continue }
                let sourceLabel = NSTextField(labelWithString: sourceProfile.displayName)
                sourceLabel.alignment = .right
                sourceLabel.frame.size.width = 110

                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.target = self
                popup.action = #selector(handleSeparateDestinationChanged(_:))
                popup.tag = index
                popup.setAccessibilityIdentifier(
                    "BrowserImportDestinationPopup-\(accessibilitySlug(for: sourceProfile, index: index))"
                )

                let options = destinationOptions(for: entry, sourceProfile: sourceProfile)
                separateDestinationOptionsByEntryIndex[index] = options
                for option in options {
                    popup.addItem(withTitle: title(for: option))
                }
                if let selectedIndex = options.firstIndex(of: entry.destination) {
                    popup.selectItem(at: selectedIndex)
                } else {
                    popup.selectItem(at: 0)
                }
                popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
                popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                let row = NSStackView(views: [sourceLabel, popup])
                row.orientation = .horizontal
                row.spacing = 6
                row.alignment = .centerY
                row.distribution = .fill
                separateDestinationRows.addArrangedSubview(row)
            }
        }

        private func rebuildMergeDestinationRow() {
            for arrangedSubview in mergeDestinationRow.arrangedSubviews {
                mergeDestinationRow.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            mergeDestinationPopup.removeAllItems()
            for profile in destinationProfiles {
                mergeDestinationPopup.addItem(withTitle: profile.displayName)
            }
            if let selectedIndex = destinationProfiles.firstIndex(where: { $0.id == resolvedMergeDestinationProfileID() }) {
                mergeDestinationPopup.selectItem(at: selectedIndex)
            } else {
                mergeDestinationPopup.selectItem(at: 0)
                if let firstProfile = destinationProfiles.first {
                    mergeDestinationProfileID = firstProfile.id
                }
            }
            mergeDestinationPopup.setAccessibilityIdentifier("BrowserImportDestinationPopup-merge")

            let destinationLabel = NSTextField(
                labelWithString: String(
                    localized: "browser.import.destinationProfile",
                    defaultValue: "Import into"
                )
            )
            destinationLabel.alignment = .right
            destinationLabel.frame.size.width = 110

            mergeDestinationRow.addArrangedSubview(destinationLabel)
            mergeDestinationRow.addArrangedSubview(mergeDestinationPopup)
        }

        private func destinationOptions(
            for entry: BrowserImportExecutionEntry,
            sourceProfile: InstalledBrowserProfile
        ) -> [BrowserImportDestinationRequest] {
            var options = destinationProfiles.map { BrowserImportDestinationRequest.existing($0.id) }
            let createName: String
            switch entry.destination {
            case .createNamed(let name):
                createName = name
            case .existing:
                createName = sourceProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !createName.isEmpty,
               !destinationProfiles.contains(where: {
                   $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                       .localizedCaseInsensitiveCompare(createName) == .orderedSame
               }) {
                options.append(.createNamed(createName))
            }
            return options
        }

        private func title(for request: BrowserImportDestinationRequest) -> String {
            switch request {
            case .existing(let id):
                return destinationProfiles.first(where: { $0.id == id })?.displayName
                    ?? BrowserProfileStore.shared.displayName(for: id)
            case .createNamed(let name):
                return String(
                    format: String(
                        localized: "browser.import.destinationProfile.create",
                        defaultValue: "Create \"%@\""
                    ),
                    name
                )
            }
        }

        private func destinationProfileID(for entry: BrowserImportExecutionEntry) -> UUID? {
            guard case .existing(let id) = entry.destination else { return nil }
            return id
        }

        private func resolvedMergeDestinationProfileID() -> UUID {
            if destinationProfiles.contains(where: { $0.id == mergeDestinationProfileID }) {
                return mergeDestinationProfileID
            }
            return initialDestinationProfileID
        }

        private func defaultSeparateDestinationRequest(
            for profile: InstalledBrowserProfile
        ) -> BrowserImportDestinationRequest {
            BrowserImportPlanResolver.separateProfilesPlan(
                selectedSourceProfiles: [profile],
                destinationProfiles: destinationProfiles
            ).entries.first?.destination ?? .createNamed(profile.displayName)
        }

        private func accessibilitySlug(for profile: InstalledBrowserProfile, index: Int) -> String {
            let base = profile.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return base.isEmpty ? "profile-\(index)" : base
        }

        private func updateSourceProfilesPresentation(for browser: InstalledBrowserCandidate) {
            let presentation = BrowserImportSourceProfilesPresentation(profileCount: browser.profiles.count)
            sourceProfilesScrollHeightConstraint?.constant = presentation.scrollHeight
            sourceProfilesHelpLabel.isHidden = !presentation.showsHelpText
        }

        private func updateAdditionalDataNoteVisibility() {
            additionalDataNoteLabel.isHidden = additionalDataCheckbox.state != .on
        }

        private func updatePanelSize() {
            let contentSize = preferredContentSize()
            let targetFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))

            guard panel.frame.size != targetFrame.size else { return }
            if !panel.isVisible {
                panel.setContentSize(contentSize)
                return
            }

            var frame = panel.frame
            frame.origin.x -= (targetFrame.width - frame.width) / 2
            frame.origin.y -= (targetFrame.height - frame.height) / 2
            frame.size = targetFrame.size
            panel.setFrame(frame, display: true)
        }

        private func preferredContentSize() -> NSSize {
            switch step {
            case .source:
                return NSSize(width: 560, height: 292)
            case .sourceProfiles:
                let presentation = BrowserImportSourceProfilesPresentation(profileCount: selectedBrowser().profiles.count)
                let helpHeight: CGFloat = presentation.showsHelpText ? 24 : 0
                let height = 214 + presentation.scrollHeight + helpHeight
                return NSSize(width: 560, height: min(max(height, 292), 360))
            case .dataTypes:
                var height: CGFloat = currentExecutionPlan().mode == .separateProfiles ? 412 : 374
                if additionalDataCheckbox.state == .on {
                    height += 24
                }
                return NSSize(width: 560, height: height)
            }
        }

        private func finishModal(with response: NSApplication.ModalResponse) {
            guard !didFinishModal else { return }
            didFinishModal = true

            if NSApp.modalWindow == panel {
                NSApp.stopModal(withCode: response)
            }
            panel.orderOut(nil)
        }
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

        let subtitleLabel = NSTextField(
            labelWithString: String(
                localized: "browser.import.progress.subtitle",
                defaultValue: "This can take a few seconds for large profiles."
            )
        )
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
        let lines = BrowserImportOutcomeFormatter.lines(for: outcome)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.import.complete.title",
            defaultValue: "Browser data import complete"
        )
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
