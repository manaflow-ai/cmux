import Foundation
import CmuxCore
import CmuxSettings
import Combine
import WebKit
import AppKit
import Bonsplit
import CmuxBrowserPanel
import CmuxTerminalCore
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
import CmuxTerminal
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

enum BrowserAddressBarFocusSelectionIntent: Equatable {
    case preserveFieldEditorSelection
    case selectAll

    var shouldSelectAll: Bool {
        self == .selectAll
    }
}

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

private struct BrowserFocusModePlainEscapeEventFingerprint: Equatable {
    let type: NSEvent.EventType
    let timestamp: TimeInterval
    let windowNumber: Int
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags.RawValue

    init(_ event: NSEvent) {
        self.type = event.type
        self.timestamp = event.timestamp
        self.windowNumber = event.windowNumber
        self.keyCode = event.keyCode
        self.modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
            .rawValue
    }
}

enum GhosttyBackgroundTheme {
    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        WindowAppearanceSnapshot.clampedOpacity(opacity)
    }

    static func color(backgroundColor: NSColor, opacity: Double) -> NSColor {
        WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: opacity
        )
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

    static func apply(_ mode: BrowserThemeMode, to webView: WKWebView) {
        switch mode {
        case .system:
            webView.appearance = nil
        case .light:
            webView.appearance = NSAppearance(named: .aqua)
        case .dark:
            webView.appearance = NSAppearance(named: .darkAqua)
        }
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

struct BrowserProfileClearOutcome: Sendable {
    let profile: BrowserProfileDefinition
    let clearedWebsiteDataTypes: [String]
    let clearedHistory: Bool

    var socketPayload: [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.displayName,
            "slug": profile.slug,
            "built_in_default": profile.isBuiltInDefault,
            "cleared_website_data_types": clearedWebsiteDataTypes,
            "cleared_history": clearedHistory,
        ]
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

    func deleteProfile(id: UUID) -> BrowserProfileDefinition? {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isBuiltInDefault else {
            return nil
        }
        let removed = profiles.remove(at: index)
        let historyDirectoryURL = historyFileURL(for: id)?.deletingLastPathComponent()
        historyStores[id]?.cancelPendingSaves()
        dataStores.removeValue(forKey: id)
        historyStores.removeValue(forKey: id)
        if lastUsedProfileID == id {
            lastUsedProfileID = Self.builtInDefaultProfileID
            defaults.set(lastUsedProfileID.uuidString, forKey: Self.lastUsedProfileDefaultsKey)
        }
        persist()
        if let historyDirectoryURL {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: historyDirectoryURL)
            }
        }
        return removed
    }

    func clearProfileData(id: UUID) async -> BrowserProfileClearOutcome? {
        guard let profile = profileDefinition(id: id) else { return nil }
        let store = websiteDataStore(for: id)
        let historyURL = historyFileURL(for: id)
        historyStore(for: id).clearHistoryWithoutLoadingPersistedFile()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
        if let historyURL {
            await Self.removeItemIfExists(at: historyURL)
        }
        return BrowserProfileClearOutcome(
            profile: profile,
            clearedWebsiteDataTypes: Array(dataTypes).sorted(),
            clearedHistory: true
        )
    }

    @Sendable private nonisolated static func removeItemIfExists(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
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

    static let openSidebarPortLinksInCmuxBrowserKey = "browserOpenSidebarPortLinksInCmuxBrowser"
    static let defaultOpenSidebarPortLinksInCmuxBrowser: Bool = true

    static let interceptTerminalOpenCommandInCmuxBrowserKey = "browserInterceptTerminalOpenCommandInCmuxBrowser"
    static let defaultInterceptTerminalOpenCommandInCmuxBrowser: Bool = true

    static let browserHostWhitelistKey = "browserHostWhitelist"
    static let defaultBrowserHostWhitelist: String = ""
    static let browserExternalOpenPatternsKey = "browserExternalOpenPatterns"
    static let defaultBrowserExternalOpenPatterns: String = ""

    static func openTerminalLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) == nil {
            return defaultOpenTerminalLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
    }

    static func openSidebarPullRequestLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPullRequestLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPullRequestLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPullRequestLinksInCmuxBrowserKey)
    }

    static func openSidebarPortLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPortLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPortLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPortLinksInCmuxBrowserKey)
    }

    static func interceptTerminalOpenCommandInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
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
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return true }

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

enum BrowserAvailabilitySettings {
    static let disabledKey = "browserDisabledOverride"
    static let didChangeNotification = Notification.Name("cmux.browserAvailabilityDidChange")
    static let defaultDisabled = false

    static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        // No synchronize() on read: it forces a blocking prefs-plist reload on a path hit from link-open/pane-create; UserDefaults stays coherent in-process and via cfprefsd.
        if defaults.object(forKey: disabledKey) == nil {
            return defaultDisabled
        }
        return defaults.bool(forKey: disabledKey)
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !isDisabled(defaults: defaults)
    }

    static func setDisabled(_ disabled: Bool, defaults: UserDefaults = .standard) {
        // `set` already persists; `synchronize()` is a deprecated no-op-style fsync.
        defaults.set(disabled, forKey: disabledKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

enum BrowserInsecureHTTPSettings {
    static let allowlistKey = "browserInsecureHTTPAllowlist"
    static let defaultAllowlistPatterns = [
        "localhost",
        "*.localhost",
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

    // Single source of truth: the host normalizer moved to CmuxCore with the
    // loopback alias lift; this forwards so allowlist semantics stay identical.
    static func normalizeHost(_ rawHost: String) -> String? {
        RemoteLoopbackProxyAlias.normalizeHost(rawHost)
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

/// Carries the request and one-shot HTTP bypass needed to seed a retargeted tab.
struct BrowserNewTabNavigationSeed {
    let url: URL
    let initialRequest: URLRequest
    let bypassInsecureHTTPHostOnce: String?
}

/// Preserves the original request metadata for a retargeted new-tab navigation.
func browserNewTabNavigationSeed(
    from request: URLRequest,
    bypassInsecureHTTPHostOnce: String? = nil
) -> BrowserNewTabNavigationSeed? {
    guard let url = request.url else { return nil }
    return BrowserNewTabNavigationSeed(
        url: url,
        initialRequest: request,
        bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
    )
}

/// Mirrors the opener's WebKit browsing context for popup windows.
struct BrowserPopupBrowserContext {
    let websiteDataStore: WKWebsiteDataStore
}

enum BrowserFileSystemAccessBridge {
    static let scriptSource = """
    (() => {
      if (typeof window.showOpenFilePicker === "function") {
        return true;
      }
      if (window.__cmuxFileSystemAccessBridgeInstalled) {
        return true;
      }
      window.__cmuxFileSystemAccessBridgeInstalled = true;

      const makeDOMException = (name, message) => {
        try {
          return new DOMException(message, name);
        } catch (_) {
          const error = new Error(message);
          error.name = name;
          return error;
        }
      };

      const normalizeAcceptToken = (value) => {
        if (typeof value !== "string") {
          return null;
        }
        const token = value.trim();
        return token.length > 0 ? token : null;
      };

      const acceptStringFromTypes = (types) => {
        if (!Array.isArray(types)) {
          return "";
        }

        const seen = new Set();
        const tokens = [];
        const pushToken = (value) => {
          const token = normalizeAcceptToken(value);
          if (token && !seen.has(token)) {
            seen.add(token);
            tokens.push(token);
          }
        };

        for (const type of types) {
          const accept = type && type.accept;
          if (!accept || typeof accept !== "object") {
            continue;
          }

          for (const [mimeType, extensions] of Object.entries(accept)) {
            pushToken(mimeType);
            if (Array.isArray(extensions)) {
              for (const extension of extensions) {
                pushToken(extension);
              }
            } else {
              pushToken(extensions);
            }
          }
        }

        return tokens.join(",");
      };

      const FileSystemHandleShim = window.FileSystemHandle || function FileSystemHandle() {};
      const FileSystemFileHandleShim = window.FileSystemFileHandle || function FileSystemFileHandle() {};
      if (typeof window.FileSystemHandle !== "function") {
        Object.defineProperty(window, "FileSystemHandle", {
          value: FileSystemHandleShim,
          configurable: true,
          writable: true,
        });
      }
      if (typeof window.FileSystemFileHandle !== "function") {
        FileSystemFileHandleShim.prototype = Object.create(FileSystemHandleShim.prototype);
        Object.defineProperty(FileSystemFileHandleShim.prototype, "constructor", {
          value: FileSystemFileHandleShim,
          configurable: true,
          writable: true,
        });
        Object.defineProperty(window, "FileSystemFileHandle", {
          value: FileSystemFileHandleShim,
          configurable: true,
          writable: true,
        });
      }

      const makeFileHandle = (file) => {
        const handle = Object.create(window.FileSystemFileHandle.prototype);
        Object.defineProperties(handle, {
          kind: {
            value: "file",
            enumerable: true,
          },
          name: {
            value: file.name,
            enumerable: true,
          },
          getFile: {
            value: () => Promise.resolve(file),
          },
          isSameEntry: {
            value: (other) => Promise.resolve(other === handle),
          },
          queryPermission: {
            value: () => Promise.resolve("granted"),
          },
          requestPermission: {
            value: () => Promise.resolve("granted"),
          },
        });
        return handle;
      };

      const filePickerDismissedError = () => makeDOMException(
        "AbortError",
        "The file picker was dismissed."
      );

      const cleanupInput = (input) => {
        if (input && input.parentNode) {
          input.parentNode.removeChild(input);
        }
      };

      const showOpenFilePicker = (options = {}) => new Promise((resolve, reject) => {
        const input = document.createElement("input");
        input.type = "file";
        input.multiple = options && options.multiple === true;
        const accept = acceptStringFromTypes(options && options.types);
        if (accept) {
          input.accept = accept;
        }
        input.style.position = "fixed";
        input.style.left = "-10000px";
        input.style.top = "0";
        input.style.width = "1px";
        input.style.height = "1px";
        input.style.opacity = "0";
        input.tabIndex = -1;

        let settled = false;
        let focusFallbackScheduled = false;
        let focusFallbackTimer = null;
        const currentFiles = () => Array.from(input.files || []);
        const cleanup = () => {
          if (focusFallbackTimer !== null) {
            clearTimeout(focusFallbackTimer);
            focusFallbackTimer = null;
          }
          input.removeEventListener("change", handleChange);
          input.removeEventListener("cancel", handleCancel);
          window.removeEventListener("focus", handleWindowFocus);
          cleanupInput(input);
        };
        const settle = (callback) => {
          if (settled) {
            return;
          }
          settled = true;
          cleanup();
          callback();
        };

        const resolveFiles = () => {
          const files = currentFiles();
          settle(() => resolve(files.map(makeFileHandle)));
        };

        const dismissPicker = () => {
          settle(() => reject(filePickerDismissedError()));
        };

        function handleChange() {
          resolveFiles();
        }

        function handleCancel() {
          dismissPicker();
        }

        function handleWindowFocus() {
          if (settled || focusFallbackScheduled) {
            return;
          }
          focusFallbackScheduled = true;
          // Defer one turn so a selection-triggered change event can settle first.
          focusFallbackTimer = setTimeout(() => {
            focusFallbackTimer = null;
            if (settled) {
              return;
            }
            if (currentFiles().length > 0) {
              resolveFiles();
            } else {
              dismissPicker();
            }
          }, 0);
        }

        input.addEventListener("change", handleChange);
        input.addEventListener("cancel", handleCancel);
        window.addEventListener("focus", handleWindowFocus);

        try {
          (document.body || document.documentElement).appendChild(input);
          input.click();
        } catch (error) {
          settle(() => reject(error));
        }
      });

      Object.defineProperty(window, "showOpenFilePicker", {
        value: showOpenFilePicker,
        configurable: true,
        writable: true,
      });

      return true;
    })();
    """
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
    "cmux-diff-viewer",
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

enum BrowserExternalNavigationAction: Equatable {
    case browserFallback(URL)
    case promptToOpenApp(URL)
}

func browserShouldRouteExternalNavigation(_ url: URL) -> Bool {
    return browserExternalNavigationAction(for: url) != nil
}

func browserIntentFallbackURL(for url: URL) -> URL? {
    guard url.scheme?.lowercased() == "intent" else { return nil }
    guard let intentMarker = url.absoluteString.range(of: "#Intent;") else { return nil }

    let fallbackPrefix = "S.browser_fallback_url="
    let intentBody = url.absoluteString[intentMarker.upperBound...]
    for component in intentBody.split(separator: ";", omittingEmptySubsequences: false) {
        if component == "end" { break }
        guard component.hasPrefix(fallbackPrefix) else { continue }

        let rawFallbackURL = String(component.dropFirst(fallbackPrefix.count))
        guard !rawFallbackURL.isEmpty else { return nil }

        let decodedFallbackURL = rawFallbackURL.removingPercentEncoding ?? rawFallbackURL
        guard let fallbackURL = URL(string: decodedFallbackURL),
              let fallbackScheme = fallbackURL.scheme?.lowercased(),
              fallbackScheme == "http" || fallbackScheme == "https" else {
            return nil
        }
        return fallbackURL
    }

    return nil
}

func browserExternalNavigationAction(for url: URL) -> BrowserExternalNavigationAction? {
    if let fallbackURL = browserIntentFallbackURL(for: url) {
        return .browserFallback(fallbackURL)
    }
    guard browserShouldOpenURLExternally(url) else { return nil }
    return .promptToOpenApp(url)
}

private func browserCopyExternalNavigationURL(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

func browserInteractiveModalHostWindow(_ window: NSWindow?) -> NSWindow? {
    guard let window else { return nil }
    guard window.isVisible else { return nil }
    guard window.alphaValue > 0 else { return nil }
    guard !window.ignoresMouseEvents else { return nil }
    guard !window.isExcludedFromWindowsMenu else { return nil }
    return window
}

func browserInteractiveModalHostWindow(for webView: WKWebView) -> NSWindow? {
    browserInteractiveModalHostWindow(webView.window)
}

private func browserFallbackInteractiveModalHostWindow() -> NSWindow? {
    if let keyWindow = browserInteractiveModalHostWindow(NSApp.keyWindow) {
        return keyWindow
    }
    return browserInteractiveModalHostWindow(NSApp.mainWindow)
}

typealias BrowserAlertPresenter = (
    _ alert: NSAlert,
    _ webView: WKWebView,
    _ completion: @escaping (NSApplication.ModalResponse) -> Void,
    _ cancel: @escaping () -> Void
) -> Void

func browserPresentAlert(
    _ alert: NSAlert,
    in webView: WKWebView,
    completion: @escaping (NSApplication.ModalResponse) -> Void,
    cancel: @escaping () -> Void = {}
) {
    _ = cancel
    if let window = browserInteractiveModalHostWindow(for: webView) {
        alert.beginSheetModal(for: window, completionHandler: completion)
        return
    }
    completion(alert.runModal())
}

private func browserPresentExternalNavigationPrompt(
    for url: URL,
    in webView: WKWebView,
    completion: @escaping (Bool) -> Void,
    presentAlert: BrowserAlertPresenter = browserPresentAlert
) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = String(
        localized: "browser.externalOpenPrompt.title",
        defaultValue: "Open External App?"
    )
    alert.informativeText = String(
        localized: "browser.externalOpenPrompt.message",
        defaultValue: "A web page in cmux wants to open a link in another app. You can stay in the browser instead."
    )
    alert.addButton(withTitle: String(
        localized: "browser.externalOpenPrompt.openApp",
        defaultValue: "Open App"
    ))
    alert.addButton(withTitle: String(
        localized: "browser.externalOpenPrompt.stayInBrowser",
        defaultValue: "Stay in Browser"
    ))

    let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
        completion(response == .alertFirstButtonReturn)
    }

    presentAlert(alert, webView, handleResponse) {
        completion(false)
    }
}

private func browserPresentExternalNavigationFailure(
    for url: URL,
    in webView: WKWebView,
    presentAlert: BrowserAlertPresenter = browserPresentAlert
) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(
        localized: "browser.externalOpenFailure.title",
        defaultValue: "Cannot Open Link"
    )
    alert.informativeText = String(
        localized: "browser.externalOpenFailure.message",
        defaultValue: "cmux could not open this link. You can copy it and open it in another app."
    )
    alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
    alert.addButton(withTitle: String(
        localized: "browser.externalOpenFailure.copyLink",
        defaultValue: "Copy Link"
    ))

    let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
        if response == .alertSecondButtonReturn {
            browserCopyExternalNavigationURL(url)
        }
    }

    presentAlert(alert, webView, handleResponse) {}
}

@discardableResult
private func browserOpenExternalNavigationURL(
    _ url: URL,
    source: String,
    webView: WKWebView,
    presentAlert: BrowserAlertPresenter = browserPresentAlert
) -> Bool {
    let opened = NSWorkspace.shared.open(url)
    if !opened {
        browserPresentExternalNavigationFailure(for: url, in: webView, presentAlert: presentAlert)
    }
#if DEBUG
    cmuxDebugLog(
        "browser.navigation.external source=\(source) opened=\(opened ? 1 : 0) " +
        "url=\(browserNavigationDebugURL(url))"
    )
#endif
    return opened
}

@discardableResult
func browserHandleExternalNavigation(
    _ url: URL,
    source: String,
    webView: WKWebView,
    loadFallbackRequest: (URLRequest) -> Void,
    presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert
) -> Bool {
    guard let action = browserExternalNavigationAction(for: url) else { return false }

    switch action {
    case let .browserFallback(fallbackURL):
        let request = URLRequest(url: fallbackURL)
        loadFallbackRequest(request)
#if DEBUG
        cmuxDebugLog(
            "browser.navigation.external source=\(source) opened=1 fallback=1 " +
            "fallbackURL=\(browserNavigationDebugURL(fallbackURL)) url=\(browserNavigationDebugURL(url))"
        )
#endif
        return true

    case let .promptToOpenApp(externalURL):
        browserPresentExternalNavigationPrompt(
            for: externalURL,
            in: webView,
            completion: { shouldOpenApp in
                guard shouldOpenApp else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.navigation.external source=\(source) opened=0 prompt=1 allowed=0 " +
                        "url=\(browserNavigationDebugURL(externalURL))"
                    )
#endif
                    return
                }
                browserOpenExternalNavigationURL(
                    externalURL,
                    source: source,
                    webView: webView,
                    presentAlert: presentAlert
                )
            },
            presentAlert: presentAlert
        )
        return true
    }
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

func browserIsTemporaryHistoryURL(_ url: URL?) -> Bool {
    guard let url else { return false }
    if url.scheme?.lowercased() == CmuxDiffViewerURLSchemeHandler.scheme {
        return true
    }
    guard url.fragment == "cmux-diff-viewer",
          url.scheme?.lowercased() == "http",
          let host = url.host else {
        return false
    }
    return RemoteLoopbackProxyAlias.isLoopbackHost(host) ||
        RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) != nil
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

    // Single source of truth for history. `private(set)` + `@MainActor` means
    // every mutation runs through this setter, so dropping the derived
    // suggestion cache here is the one enforced invalidation point. Setting it
    // to nil both frees the retained Entry/URL strings promptly (so clearing
    // history does not leave browsing history resident in the cache) and forces
    // a rebuild on next use. It must stay `@Published` for SwiftUI observation.
    // Do not add a writer that bypasses this setter (e.g. an unsafe-buffer bulk
    // write or an external `Binding<[Entry]>`) without dropping the cache.
    @Published private(set) var entries: [Entry] = [] {
        didSet { cachedSuggestionCandidates = nil }
    }

    private let fileURL: URL?
    private var didLoad: Bool = false
    private var saveTask: Task<Void, Never>?
    private let maxEntries: Int = 5000
    private let saveDebounceNanoseconds: UInt64 = 120_000_000

    var isLoaded: Bool {
        didLoad
    }

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

    // Lazily built, lowercased/parsed match fields for every entry. Building a
    // SuggestionCandidate parses the URL (URLComponents) and lowercases five
    // fields; doing that for all entries on every omnibar keystroke pegged the
    // main thread once history grew to a few thousand rows (the typing
    // beachball). `nil` means "not built / just invalidated"; it is rebuilt only
    // when `entries` changes (via the didSet above), so steady-state typing
    // reuses it and pays only the cheap substring scoring in `suggestionScore`.
    private var cachedSuggestionCandidates: [SuggestionCandidate]?

    /// Number of suggestion candidates currently resident in the cache, or 0
    /// when the cache has been invalidated. Used by tests to verify that
    /// clearing history drops the retained candidates promptly.
    var residentSuggestionCandidateCount: Int { cachedSuggestionCandidates?.count ?? 0 }

    private func suggestionCandidates() -> [SuggestionCandidate] {
        if let cached = cachedSuggestionCandidates { return cached }
        let built = entries.map(makeSuggestionCandidate)
        cachedSuggestionCandidates = built
        return built
    }

    init(fileURL: URL? = nil) {
        // Avoid calling @MainActor-isolated static methods from default argument context.
        self.fileURL = fileURL ?? BrowserHistoryStore.defaultHistoryFileURL()
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true; if let seededEntries = BrowserHistoryStore.uiTestSeedEntriesIfConfigured() { entries = seededEntries.sorted { $0.lastVisited > $1.lastVisited }; return }
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
        guard !browserIsTemporaryHistoryURL(url) else { return }
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
        guard !browserIsTemporaryHistoryURL(url) else { return }
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

        let matched = suggestionCandidates().compactMap { candidate -> ScoredSuggestion? in
            guard let score = suggestionScore(candidate: candidate, query: q, queryTokens: queryTokens, now: now) else {
                return nil
            }
            return ScoredSuggestion(entry: candidate.entry, score: score)
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

    func clearHistoryWithoutLoadingPersistedFile() {
        saveTask?.cancel()
        saveTask = nil
        didLoad = true
        entries = []
    }

    func cancelPendingSaves() {
        saveTask?.cancel()
        saveTask = nil
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
        case .brave, .perplexity, .exa, .yahoo, .ecosia, .qwant, .mojeek, .wikipedia, .github, .baidu, .yandex, .custom:
            url = nil
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

/// BrowserPanel provides a WKWebView-based browser panel.
/// Each browser panel can recover from WebContent crashes by replacing its web view.
private enum BrowserInsecureHTTPNavigationIntent {
    case currentTab
    case newTab
}

nonisolated enum BrowserWebViewLifecycleState: String {
    case newTab = "new_tab"
    case deferredURL = "deferred_url"
    case liveVisible = "live_visible"
    case liveHidden = "live_hidden"
    case discarded
    case closing
}

final class CmuxDiffViewerURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-diff-viewer"
    static let shared = CmuxDiffViewerURLSchemeHandler()
    static let maxRegisteredFiles = 1024

    struct RegisteredFile {
        let requestPath: String
        let fileURL: URL
        let mimeType: String
    }

    private struct Session {
        let token: String
        let filesByPath: [String: RegisteredFile]
        let createdAt: Date
    }

    private final class SchemeTaskState: @unchecked Sendable {
        let condition = NSCondition()
        var isStopped = false
        var callbacksInFlight = 0
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var activeSchemeTasks: [ObjectIdentifier: SchemeTaskState] = [:]
    private let streamQueue = DispatchQueue(label: "com.manaflow.cmux.diff-viewer-stream", qos: .userInitiated)
    private let maxSessionAge: TimeInterval = 24 * 60 * 60
    private let trustedRootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    func register(token: String, files: [RegisteredFile], now: Date = Date()) throws {
        guard Self.isValidToken(token) else {
            throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid diff viewer token"
            ])
        }
        guard !files.isEmpty else {
            throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Diff viewer allowlist is empty"
            ])
        }

        var byPath: [String: RegisteredFile] = [:]
        for file in files {
            guard Self.isValidRequestPath(file.requestPath),
                  Self.isAllowedMimeType(file.mimeType),
                  Self.pathExtensionMatchesMimeType(path: file.requestPath, mimeType: file.mimeType) else {
                throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid diff viewer allowlist entry"
                ])
            }

            let standardizedURL = file.fileURL.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard isTrustedDiffViewerFileURL(standardizedURL),
                  FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: standardizedURL.path) else {
                throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Diff viewer file is not readable"
                ])
            }
            guard byPath[file.requestPath] == nil else {
                throw NSError(domain: "CmuxDiffViewerURLSchemeHandler", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Duplicate diff viewer allowlist entry"
                ])
            }

            byPath[file.requestPath] = RegisteredFile(
                requestPath: file.requestPath,
                fileURL: standardizedURL,
                mimeType: file.mimeType
            )
        }

        lock.lock()
        pruneExpiredSessionsLocked(now: now)
        sessions[token] = Session(token: token, filesByPath: byPath, createdAt: now)
        lock.unlock()
    }

    /// Whether the token currently has a registered (or manifest-restorable)
    /// session. Used to trust-gate native bridge calls from diff viewer pages.
    func hasActiveSession(token: String, now: Date = Date()) -> Bool {
        guard Self.isValidToken(token) else { return false }
        lock.lock()
        pruneExpiredSessionsLocked(now: now)
        let isRegistered = sessions[token] != nil
        lock.unlock()
        if isRegistered {
            return true
        }
        return registerFromManifest(token: token, now: now)
    }

    func registeredFile(for url: URL, now: Date = Date()) -> RegisteredFile? {
        guard url.scheme == Self.scheme,
              let token = url.host,
              url.query == nil,
              url.fragment == nil,
              Self.isValidToken(token) else {
            return nil
        }
        guard let requestPath = Self.requestPath(for: url) else {
            return nil
        }

        lock.lock()
        pruneExpiredSessionsLocked(now: now)
        let file = sessions[token]?.filesByPath[requestPath]
        lock.unlock()
        return file
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let file = registeredFile(for: requestURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        startStreamingFile(file, requestURL: requestURL, urlSchemeTask: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        stopSchemeTask(taskID)
    }

    static func registeredFile(from object: [String: Any]) -> RegisteredFile? {
        guard let requestPath = object["request_path"] as? String,
              let filePath = object["file_path"] as? String,
              let mimeType = object["mime_type"] as? String else {
            return nil
        }
        return RegisteredFile(
            requestPath: requestPath,
            fileURL: URL(fileURLWithPath: filePath, isDirectory: false),
            mimeType: mimeType
        )
    }

    /// Re-registers a diff viewer token from its on-disk manifest so the surface
    /// can be served again after an app restart (the in-memory registry is lost,
    /// but the manifest + files persist in the trusted diff viewer directory).
    /// Returns `true` when the token is registered and ready to serve.
    func registerFromManifest(token: String, now: Date = Date()) -> Bool {
        guard let files = localManifestFiles(token: token) else { return false }
        do {
            try register(token: token, files: files, now: now)
            return true
        } catch {
            return false
        }
    }

    /// Loads the registered files for a token's on-disk manifest, or `nil` when
    /// the manifest is missing, empty, or references remote patch entries
    /// (`remote_url` / empty `file_path`) that the local-file scheme handler
    /// cannot serve. Streamed remote PR diffs fall into the latter case.
    private func localManifestFiles(token: String) -> [RegisteredFile]? {
        guard Self.isValidToken(token) else { return nil }
        let manifestURL = trustedRootURL.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileObjects = object["files"] as? [[String: Any]],
              !fileObjects.isEmpty else {
            return nil
        }
        var files: [RegisteredFile] = []
        for fileObject in fileObjects {
            let filePath = fileObject["file_path"] as? String ?? ""
            if fileObject["remote_url"] is String || filePath.isEmpty {
                return nil
            }
            guard let file = Self.registeredFile(from: fileObject) else { return nil }
            files.append(file)
        }
        return files
    }

    /// Whether a diff viewer surface can be restored through the custom scheme.
    /// Requires a local-only manifest and an entry page that is neither a
    /// pending placeholder nor a redirect stub. Pending pages poll a
    /// deferred-load wait endpoint, and redirect pages bounce to the original
    /// `http://127.0.0.1:<port>` URL; both only work against the local HTTP
    /// server, which is gone after restart, so they would fail under the
    /// custom scheme.
    func diffViewerRestorable(token: String, requestPath: String) -> Bool {
        guard let files = localManifestFiles(token: token),
              let entry = files.first(where: { $0.requestPath == requestPath }),
              let handle = try? FileHandle(forReadingFrom: entry.fileURL) else {
            return false
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        if let text = String(data: head, encoding: .utf8),
           text.contains("data-cmux-diff-pending=\"true\"") || text.contains("data-cmux-diff-redirect") {
            return false
        }
        return true
    }

    /// Extracts the diff viewer `(token, requestPath)` from a live diff viewer
    /// URL, accepting both the custom scheme (`cmux-diff-viewer://<token>/<path>`)
    /// and the local HTTP server form (`http://127.0.0.1:<port>/<token>/<path>#cmux-diff-viewer`).
    static func diffViewerComponents(from url: URL?) -> (token: String, requestPath: String)? {
        guard let url else { return nil }
        if url.scheme == scheme, let token = url.host, isValidToken(token) {
            guard let requestPath = requestPath(for: url) else { return nil }
            return (token, requestPath)
        }
        if (url.scheme == "http" || url.scheme == "https"),
           url.host == "127.0.0.1",
           url.fragment == Self.scheme {
            let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, isValidToken(parts[0]) else { return nil }
            let requestPath = "/" + parts.dropFirst().joined(separator: "/")
            guard isValidRequestPath(requestPath) else { return nil }
            return (parts[0], requestPath)
        }
        return nil
    }

    /// Builds the app-owned custom-scheme URL used to restore a diff viewer
    /// surface, decoupled from the local HTTP server. No fragment, so
    /// `registeredFile(for:)` serves it.
    static func diffViewerURL(token: String, requestPath: String) -> URL? {
        guard isValidToken(token), isValidRequestPath(requestPath) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = token
        components.percentEncodedPath = requestPath
        return components.url
    }

    static func isValidToken(_ token: String) -> Bool {
        guard (16...80).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }

    static func isValidRequestPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("//") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    static func requestPath(for url: URL) -> String? {
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let requestPath = rawPath.isEmpty ? "/" : rawPath
        guard isValidRequestPath(requestPath) else { return nil }
        return requestPath
    }

    private static func isAllowedMimeType(_ mimeType: String) -> Bool {
        mimeType == "text/html" || mimeType == "text/javascript" || mimeType == "text/x-diff"
    }

    private static func pathExtensionMatchesMimeType(path: String, mimeType: String) -> Bool {
        if mimeType == "text/html" {
            return path.hasSuffix(".html")
        }
        if mimeType == "text/javascript" {
            return path.hasSuffix(".mjs") || path.hasSuffix(".js")
        }
        if mimeType == "text/x-diff" {
            return path.hasSuffix(".patch")
        }
        return false
    }

    private func startStreamingFile(
        _ file: RegisteredFile,
        requestURL: URL,
        urlSchemeTask: WKURLSchemeTask
    ) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let state = SchemeTaskState()
        lock.lock()
        activeSchemeTasks[taskID] = state
        lock.unlock()

        streamQueue.async { [weak self] in
            guard let self else { return }
            do {
                let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: self.responseHeaders(for: file)
                ) ?? URLResponse(
                    url: requestURL,
                    mimeType: file.mimeType,
                    expectedContentLength: Self.fileSize(for: file.fileURL),
                    textEncodingName: "utf-8"
                )

                guard self.performSchemeTaskCallback(taskID, {
                    urlSchemeTask.didReceive(response)
                }) else { return }

                let handle = try FileHandle(forReadingFrom: file.fileURL)
                defer {
                    try? handle.close()
                }

                while self.isSchemeTaskActive(taskID) {
                    let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                    if data.isEmpty {
                        break
                    }
                    guard self.performSchemeTaskCallback(taskID, {
                        urlSchemeTask.didReceive(data)
                    }) else { return }
                }

                guard self.performSchemeTaskCallback(taskID, {
                    urlSchemeTask.didFinish()
                }) else { return }
                self.finishSchemeTask(taskID)
            } catch {
                guard self.performSchemeTaskCallback(taskID, {
                    urlSchemeTask.didFailWithError(error)
                }) else { return }
                self.finishSchemeTask(taskID)
            }
        }
    }

    private func isSchemeTaskActive(_ taskID: ObjectIdentifier) -> Bool {
        lock.lock()
        let state = activeSchemeTasks[taskID]
        lock.unlock()
        guard let state else { return false }

        state.condition.lock()
        let active = !state.isStopped
        state.condition.unlock()
        return active
    }

    private func performSchemeTaskCallback(_ taskID: ObjectIdentifier, _ callback: () -> Void) -> Bool {
        lock.lock()
        let state = activeSchemeTasks[taskID]
        lock.unlock()
        guard let state else { return false }

        state.condition.lock()
        guard !state.isStopped else {
            state.condition.unlock()
            return false
        }
        state.callbacksInFlight += 1
        state.condition.unlock()

        callback()

        state.condition.lock()
        state.callbacksInFlight -= 1
        if state.callbacksInFlight == 0 {
            state.condition.broadcast()
        }
        let active = !state.isStopped
        state.condition.unlock()
        return active
    }

    private func finishSchemeTask(_ taskID: ObjectIdentifier) {
        stopSchemeTask(taskID)
    }

    private func stopSchemeTask(_ taskID: ObjectIdentifier) {
        lock.lock()
        let state = activeSchemeTasks.removeValue(forKey: taskID)
        lock.unlock()
        guard let state else { return }

        state.condition.lock()
        state.isStopped = true
        while state.callbacksInFlight > 0 {
            state.condition.wait()
        }
        state.condition.unlock()
    }

    private static func fileSize(for url: URL) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return -1
        }
        return fileSize
    }

    private func isTrustedDiffViewerFileURL(_ url: URL) -> Bool {
        let rootPath = trustedRootURL.path
        return url.isFileURL && url.path.hasPrefix(rootPath + "/")
    }

    private func pruneExpiredSessionsLocked(now: Date) {
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.createdAt) <= maxSessionAge
        }
    }

    private func responseHeaders(for file: RegisteredFile) -> [String: String] {
        var headers = [
            "Content-Type": "\(file.mimeType); charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Cross-Origin-Resource-Policy": "same-origin"
        ]
        if file.mimeType == "text/html" {
            headers["Content-Security-Policy"] = [
                "default-src 'none'",
                "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'",
                "style-src 'unsafe-inline'",
                "img-src 'self' data:",
                "connect-src 'self'",
                "font-src 'none'",
                "object-src 'none'",
                "base-uri 'none'",
                "form-action 'none'"
            ].joined(separator: "; ")
        }
        return headers
    }
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

    let id: UUID
    let panelType: PanelType = .browser

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    @Published private(set) var profileID: UUID
    @Published private(set) var historyStore: BrowserHistoryStore

    /// The underlying web view
    private(set) var webView: WKWebView
    private var websiteDataStore: WKWebsiteDataStore
    var webViewDidRequestClose: (() -> Void)?

    /// Monotonic identity for the current WKWebView instance.
    /// Incremented whenever we replace the underlying WKWebView after a process crash.
    @Published private(set) var webViewInstanceID: UUID = UUID()
    private(set) var hasRecoverableWebContentTermination = false {
        willSet {
            if newValue != hasRecoverableWebContentTermination {
                objectWillChange.send()
            }
        }
    }
    private var pendingWebContentRecoveryURL: URL?

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
    @Published private(set) var currentURL: URL? {
        didSet {
            guard oldValue != currentURL else { return }
            applyConfiguredWebViewBackground()
        }
    }

    /// Whether the browser panel should render its WKWebView in the content area.
    /// New browser tabs stay in an empty "new tab" state until first navigation.
    @Published private(set) var shouldRenderWebView: Bool = false {
        didSet {
            if oldValue != shouldRenderWebView {
                refreshWebViewLifecycleState()
                applyConfiguredWebViewBackground()
            }
        }
    }
    @Published private(set) var backgroundAppearanceRevision: UInt64 = 0
    private let hiddenWebViewDiscardManager = BrowserHiddenWebViewDiscardManager()

    @Published private(set) var webViewLifecycleState: BrowserWebViewLifecycleState = .newTab
    private(set) var webViewLastVisibleAt: Date?
    private(set) var webViewLastHiddenAt: Date?
    private(set) var webViewLastVisibilityChangeAt: Date?
    private(set) var webViewLastVisibilityChangeReason: String?
    var hasBackgroundPreloadHost: Bool {
        backgroundPreloadWindow != nil
    }
    private var shouldPreloadInitialNavigationInBackground: Bool
    private var backgroundPreloadWindow: NSWindow?
    private let visualAutomationCaptureGate = BrowserScreenshotCaptureGate()
    private var activeVisualAutomationCaptureCount: Int = 0
    private struct PendingInteractiveBrowserPrompt {
        let present: (NSWindow, @escaping () -> Void) -> Void
        let cancel: () -> Void
    }
    private var pendingInteractiveBrowserPrompts: [PendingInteractiveBrowserPrompt] = []
    private var isPresentingPendingInteractiveBrowserPrompt = false
    private var isWebViewVisibleInUI: Bool = false
    private var isClosingWebViewLifecycle: Bool = false

    /// True while a canvas pane hosts this browser's webview inline (in the
    /// pane's own hierarchy). Portal-side reconcilers must not rebind or
    /// re-sync the webview into the window portal while this is set.
    var canvasInlineHostingActive: Bool = false

    /// True when the browser is showing the internal empty new-tab page.
    var isShowingNewTabPage: Bool {
        !shouldRenderWebView && preferredURLStringForOmnibar() == nil
    }

    var isShowingBlankBrowserPage: Bool {
        Self.isBlankBrowserPage(
            liveURL: Self.remoteProxyDisplayURL(for: webView.url) ?? webView.url,
            currentURL: currentURL,
            pendingNavigationURL: Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)
                ?? navigationDelegate?.lastAttemptedURL,
            isMainFrameProvisionalNavigationActive: isMainFrameProvisionalNavigationActive
        )
    }

    /// Published page title
    @Published private(set) var pageTitle: String = ""

    /// Published favicon (PNG data). When present, the tab bar can render it instead of a SF symbol.
    @Published private(set) var faviconPNGData: Data?

    /// Published loading state
    @Published private(set) var isLoading: Bool = false

    /// Published download state for browser downloads (navigation + context menu).
    @Published private(set) var isDownloading: Bool = false

    /// Per-pane browser audio mute intent. BrowserPanel owns this so the state
    /// survives WKWebView replacement and can be applied to each new page.
    @Published private(set) var isMuted: Bool = false

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
    private var isMainFrameProvisionalNavigationActive: Bool = false

    /// Published estimated progress (0.0 - 1.0)
    @Published private(set) var estimatedProgress: Double = 0.0

    /// Increment to request a UI-only flash highlight (e.g. from a keyboard shortcut).
    @Published private(set) var focusFlashToken: Int = 0

    /// Browser focus mode gives the focused WKWebView first ownership of page/app shortcuts.
    @Published private(set) var isBrowserFocusModeActive: Bool = false

    /// A first plain Escape in browser focus mode is forwarded to the page and arms exit.
    @Published private(set) var isBrowserFocusModeExitArmed: Bool = false

    private static let browserFocusModeEscapeSequenceInterval: TimeInterval = 1.6
    private var browserFocusModeExitArmedAt: TimeInterval?
    private var lastBrowserFocusModePlainEscapeEventFingerprint: BrowserFocusModePlainEscapeEventFingerprint?

    /// Sticky omnibar-focus intent. This survives view mount timing races and is
    /// cleared only after BrowserPanelView acknowledges handling it.
    @Published private(set) var pendingAddressBarFocusRequestId: UUID?
    private(set) var pendingAddressBarFocusSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection

    /// Per-surface browser chrome visibility. Diff and artifact viewers can hide
    /// the omnibar without changing the global browser default.
    @Published private(set) var isOmnibarVisible: Bool

    /// Semantic in-panel focus target used by split switching and transient overlays.
    private(set) var preferredFocusIntent: BrowserPanelFocusIntent = .webView

    /// Incremented whenever async browser find focus ownership changes.
    @Published private(set) var searchFocusRequestGeneration: UInt64 = 0
    private var lastSearchNeedle = ""

    /// Find-in-page state. Non-nil when the find bar is visible.
    @Published var searchState: BrowserSearchState? = nil {
        didSet {
            if let searchState {
                clearBrowserFocusMode(reason: "searchStateCreated")
                preferredFocusIntent = .findField
#if DEBUG
                cmuxDebugLog("browser.find.state.created panel=\(id.uuidString.prefix(5))")
#endif
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
#if DEBUG
                        cmuxDebugLog("browser.find.needle.updated panel=\(self.id.uuidString.prefix(5)) bytes=\(needle.lengthOfBytes(using: .utf8))")
#endif
                        self.executeFindSearch(needle)
                    }
            } else if let oldValue {
                lastSearchNeedle = oldValue.needle
                searchNeedleCancellable = nil
                if preferredFocusIntent == .findField { preferredFocusIntent = .webView }
                invalidateSearchFocusRequests(reason: "searchStateCleared")
#if DEBUG
                cmuxDebugLog("browser.find.state.cleared panel=\(id.uuidString.prefix(5))")
#endif
                executeFindClear()
            }
        }
    }
    @Published private(set) var isElementFullscreenActive: Bool = false
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
    @Published var isReactGrabActive: Bool = false {
        didSet {
            guard oldValue != isReactGrabActive else { return }
            reevaluateHiddenWebViewDiscardScheduling(reason: "react_grab_changed")
        }
    }
    var reactGrabMessageHandler: ReactGrabMessageHandler?
    /// Whether the live page currently has any actively-playing `<video>` or
    /// `<audio>` element, in the main frame or any iframe, reported by the
    /// injected media-playback hook. Keeps an actively-playing pane alive in the
    /// background instead of being discarded after the hidden delay
    /// (https://github.com/manaflow-ai/cmux/issues/5409).
    private(set) var isPlayingMedia: Bool = false {
        didSet {
            guard oldValue != isPlayingMedia else { return }
            reevaluateHiddenWebViewDiscardScheduling(reason: "media_playback_changed")
        }
    }
    /// Document ids of the frames currently reporting playing media. The pane is
    /// kept alive while this is non-empty.
    private var playingMediaFrameIDs: Set<String> = []
    var mediaPlaybackMessageHandler: BrowserMediaPlaybackMessageHandler?

    /// Folds a per-frame playback report into ``isPlayingMedia``. Lives here so
    /// the `private(set)` setter stays confined to this file.
    func applyMediaPlaybackReport(frameID: String, isPlaying: Bool) {
        if isPlaying {
            playingMediaFrameIDs.insert(frameID)
        } else {
            playingMediaFrameIDs.remove(frameID)
        }
        isPlayingMedia = !playingMediaFrameIDs.isEmpty
    }

    /// Clears all tracked playing frames (new webview bind or main-frame
    /// navigation, where the prior frame hooks are gone).
    func resetMediaPlaybackTracking() {
        playingMediaFrameIDs.removeAll()
        isPlayingMedia = false
    }
    var pendingReactGrabReturnTargetPanelId: UUID?
    var pendingReactGrabRoundTripToken: String?
    let reactGrabBridgeSessionUpdaterName = "__cmuxReactGrabBridgeSync_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
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
    private let bypassesRemoteWorkspaceProxy: Bool
    /// Marks this surface as transparent internal cmux UI (e.g. the diff viewer
    /// or other custom UI) rather than a normal web page. When set, the webview
    /// is made fully clear over a transparent Ghostty theme so the page's own
    /// CSS owns the background. See `applyWebViewBackground(color:)`.
    private let usesTransparentBackground: Bool
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

    var currentBrowserThemeMode: BrowserThemeMode {
        browserThemeMode
    }

    @discardableResult
    private func applyMuteState(_ muted: Bool? = nil, to webView: WKWebView, reason: String) -> Bool {
        let targetMuted = muted ?? isMuted
        let applied = webView.cmuxSetPageAudioMuted(targetMuted)
#if DEBUG
        if !applied {
            cmuxDebugLog(
                "browser.audioMute.applyUnavailable panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) muted=\(targetMuted ? 1 : 0)"
            )
        }
#endif
        return applied
    }

    func noteWebViewVisibility(
        _ visible: Bool,
        reason: String,
        now: Date = Date(),
        recordIfUnchanged: Bool = false
    ) {
        let changed = isWebViewVisibleInUI != visible
        let isFirstVisibilityRecord = webViewLastVisibilityChangeReason == nil
        let shouldRecordVisibleHeartbeat = visible && recordIfUnchanged
        guard changed || shouldRecordVisibleHeartbeat || isFirstVisibilityRecord else {
            refreshWebViewLifecycleState()
            return
        }

        if changed || isFirstVisibilityRecord {
            isWebViewVisibleInUI = visible
            if visible {
                webViewLastVisibleAt = now
            } else {
                webViewLastHiddenAt = now
            }
            webViewLastVisibilityChangeAt = now
            webViewLastVisibilityChangeReason = reason
        } else if shouldRecordVisibleHeartbeat {
            webViewLastVisibleAt = now
        }
        refreshWebViewLifecycleState()

        if visible {
            cancelHiddenWebViewDiscard()
            restoreDiscardedWebViewIfNeeded(reason: "visible.\(reason)")
            drainPendingInteractiveBrowserPromptsIfPossible(reason: "visible.\(reason)")
        } else if changed || isFirstVisibilityRecord || !hiddenWebViewDiscardManager.hasScheduledDiscard {
            scheduleHiddenWebViewDiscardIfNeeded(reason: reason)
        }
    }

    func webViewLifecycleTopPayload(now: Date = Date()) -> [String: Any] {
        let discardBlockers = hiddenWebViewDiscardBlockers()
        return [
            "state": webViewLifecycleState.rawValue,
            "visible_in_ui": isWebViewVisibleInUI,
            "should_render": shouldRenderWebView,
            "discard_eligible": discardBlockers.isEmpty,
            "discard_blockers": discardBlockers,
            "discarded_at": Self.webViewLifecycleTimestamp(hiddenWebViewDiscardManager.discardedAt),
            "last_discard_reason": hiddenWebViewDiscardManager.lastDiscardReason.map { $0 as Any } ?? NSNull(),
            "last_restore_reason": hiddenWebViewDiscardManager.lastRestoreReason.map { $0 as Any } ?? NSNull(),
            "last_visible_at": Self.webViewLifecycleTimestamp(webViewLastVisibleAt),
            "last_hidden_at": Self.webViewLifecycleTimestamp(webViewLastHiddenAt),
            "last_visibility_change_at": Self.webViewLifecycleTimestamp(webViewLastVisibilityChangeAt),
            "last_visibility_change_reason": webViewLastVisibilityChangeReason.map { $0 as Any } ?? NSNull(),
            "hidden_duration_ms": Self.webViewHiddenDurationMilliseconds(
                hiddenAt: webViewLastHiddenAt,
                visible: isWebViewVisibleInUI,
                now: now
            )
        ]
    }

    private func refreshWebViewLifecycleState() {
        let nextState: BrowserWebViewLifecycleState
        if isClosingWebViewLifecycle {
            nextState = .closing
        } else if hiddenWebViewDiscardManager.isDiscardedForMemory {
            nextState = .discarded
        } else if !shouldRenderWebView {
            nextState = preferredURLStringForOmnibar() == nil ? .newTab : .deferredURL
        } else if isWebViewVisibleInUI {
            nextState = .liveVisible
        } else {
            nextState = .liveHidden
        }
        guard webViewLifecycleState != nextState else { return }
        webViewLifecycleState = nextState
    }

    private static let webViewLifecycleTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func webViewLifecycleTimestamp(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return webViewLifecycleTimestampFormatter.string(from: date)
    }

    private static func webViewHiddenDurationMilliseconds(
        hiddenAt: Date?,
        visible: Bool,
        now: Date
    ) -> Any {
        guard !visible, let hiddenAt else { return NSNull() }
        return max(0, Int((now.timeIntervalSince(hiddenAt) * 1000.0).rounded()))
    }

    private func resetWebViewLifecycleMetadata(resetVisibility: Bool = true) {
        cancelHiddenWebViewDiscard()
        webViewLifecycleState = .newTab
        if resetVisibility {
            webViewLastVisibleAt = nil
            webViewLastHiddenAt = nil
            webViewLastVisibilityChangeAt = nil
            webViewLastVisibilityChangeReason = nil
            isWebViewVisibleInUI = false
        }
        hiddenWebViewDiscardManager.resetMetadata()
        isClosingWebViewLifecycle = false
    }

    private func hiddenWebViewDiscardBlockers() -> [String] {
        hiddenWebViewDiscardManager.blockers(for: hiddenWebViewDiscardSnapshot)
    }

    private func scheduleHiddenWebViewDiscardIfNeeded(reason: String) {
        hiddenWebViewDiscardManager.scheduleIfNeeded(reason: reason)
    }

    private func cancelHiddenWebViewDiscard() {
        hiddenWebViewDiscardManager.cancel()
    }

    private func reevaluateHiddenWebViewDiscardScheduling(reason: String) {
        if isWebViewVisibleInUI {
            cancelHiddenWebViewDiscard()
        } else {
            scheduleHiddenWebViewDiscardIfNeeded(reason: reason)
        }
    }

    private func installHiddenWebViewDiscardPolicyObserver() {
        hiddenWebViewDiscardManager.installPolicyObserver()
        hiddenWebViewDiscardManager.installSystemSleepObservers()
    }

    @discardableResult
    func discardHiddenWebViewForMemory(reason: String, now: Date = Date()) -> Bool {
        let blockers = hiddenWebViewDiscardBlockers()
        guard blockers.isEmpty else { return false }

        cancelHiddenWebViewDiscard()

        let oldWebView = webView
        let restoreURL = Self.remoteProxyDisplayURL(for: oldWebView.url) ?? currentURL
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar() ?? restoreURL?.absoluteString
        let desiredZoom = max(minPageZoom, min(maxPageZoom, oldWebView.pageZoom))

        clearBrowserFocusMode(reason: "webViewDiscard")
        invalidateSearchFocusRequests(reason: "webViewDiscard")
        searchState = nil
        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        cancelPendingInteractiveBrowserPrompts(reason: "discardHiddenWebView")

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        closeBackgroundPreloadHost(reason: "discardHiddenWebView")
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
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
        hiddenWebViewDiscardManager.markDiscarded(reason: reason, now: now)
        currentURL = restoreURL
        shouldRenderWebView = false
        nativeCanGoBack = false
        nativeCanGoForward = false
        isLoading = false
        estimatedProgress = 0
        activePortalHostLease = nil
        pendingDistinctPortalHostReplacementPaneId = nil
        lockedPortalHost = nil

        bindWebView(replacement)
        applyProxyConfigurationIfAvailable()
        applyBrowserThemeModeIfNeeded()
        restoreSessionNavigationHistory(
            backHistoryURLStrings: history.backHistoryURLStrings,
            forwardHistoryURLStrings: history.forwardHistoryURLStrings,
            currentURLString: historyCurrentURL
        )
        refreshNavigationAvailability()
        refreshWebViewLifecycleState()
        return true
    }

    @discardableResult
    func restoreDiscardedWebViewIfNeeded(reason: String) -> Bool {
        return hiddenWebViewDiscardManager.restoreIfNeeded(reason: reason) {
            shouldRenderWebView = true
            guard let restoreURL = restoredHistoryCurrentURL ?? currentURL else {
                refreshNavigationAvailability()
                return
            }
            navigateWithoutInsecureHTTPPrompt(
                to: restoreURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
        }
    }

    private func clearWebViewDiscardState(reason: String) {
        guard hiddenWebViewDiscardManager.clearDiscardState(reason: reason) else { return }
        refreshWebViewLifecycleState()
    }

    @discardableResult
    private func reactivateDiscardedWebViewWithoutNavigation(reason: String) -> Bool {
        return hiddenWebViewDiscardManager.reactivateWithoutNavigation(reason: reason) {
            shouldRenderWebView = true
        }
    }

    /// Popups inherit this panel's exact WebKit storage context.
    var popupBrowserContext: BrowserPopupBrowserContext {
        BrowserPopupBrowserContext(
            websiteDataStore: websiteDataStore
        )
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
        cmuxDebugLog(
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
        if shouldUseLocalInlineDeveloperToolsHosting() {
            activePortalHostLease = nil
            lockedPortalHost = nil
#if DEBUG
            cmuxDebugLog(
                "browser.portal.host.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason).localInlineDevTools host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            return false
        }

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
                cmuxDebugLog(
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
                cmuxDebugLog(
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
            cmuxDebugLog(
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
        cmuxDebugLog(
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
        cmuxDebugLog(
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
        // Match only the unpainted/loading background so newly-created browsers don't flash
        // white before content loads. Do not force page appearance or inject color-scheme CSS;
        // websites must keep control of their own theme.
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        // Always present as Safari.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        return webView
    }

    static func configureWebViewConfiguration(
        _ configuration: WKWebViewConfiguration,
        websiteDataStore: WKWebsiteDataStore
    ) {
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Ensure browser cookies/storage persist across navigations and launches.
        // This reduces repeated consent/bot-challenge flows on sites like Google.
        configuration.websiteDataStore = websiteDataStore
        if configuration.urlSchemeHandler(forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(
                CmuxDiffViewerURLSchemeHandler.shared,
                forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme
            )
        }
        // Review-comment persistence + TextBox attach for diff viewer pages.
        // The handler itself rejects every frame that is not a registered diff
        // viewer session, so installing it on all browser webviews is safe.
        DiffCommentsBridge.installIfNeeded(on: configuration.userContentController)

        // Enable developer extras (DevTools)
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.preferences.isElementFullscreenEnabled = true

        // Enable JavaScript
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserFileSystemAccessBridge.scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Keep browser console/error/dialog telemetry active from document start on every navigation.
        // Main frame only — injecting into cross-origin iframes causes CAPTCHA providers
        // (reCAPTCHA, hCaptcha, Cloudflare Turnstile) to detect the overridden console.*
        // methods and __cmux* globals as environment tampering, failing the challenge.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.telemetryHookBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: RemoteLoopbackRuntimeBridge.runtimeBridgeScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        // Track the last editable focused element continuously so omnibar exit can
        // restore page input focus even if capture runs after first-responder handoff.
        // Main frame only — same CAPTCHA interference concern as telemetry hooks.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.addressBarFocusTrackingBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Keep a native cache of whether the focused page element can currently accept
        // plain-text paste so Cmd+Shift+V is only consumed when the browser can use it.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: CmuxWebView.pasteAsPlainTextFocusTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Report <video>/<audio> playback so a hidden pane with actively-playing
        // media is exempted from memory discard
        // (https://github.com/manaflow-ai/cmux/issues/5409). Injected into every
        // frame so embedded players in cross-origin iframes keep the pane alive
        // too. Runs in an isolated content world (shared DOM, separate JS scope)
        // so the handler is hidden from page JavaScript that could otherwise post
        // a fake playing report; this also keeps it clear of CAPTCHA fingerprint
        // checks in those iframes.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.mediaPlaybackTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: Self.mediaPlaybackContentWorld
            )
        )
    }

    private func bindWebView(_ webView: CmuxWebView) {
        DiffCommentsBridge.associate(panelId: id, workspaceId: workspaceId, with: webView)
        webView.onMouseBackButton = { [weak self] in
            self?.goBack()
        }
        webView.onMouseForwardButton = { [weak self] in
            self?.goForward()
        }
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
        configureMoveTabToNewWorkspaceContextMenu(for: webView); configureNavigationDelegateCallbacks()
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = uiDelegate
        setupObservers(for: webView)
        setupReactGrabMessageHandler(for: webView)
        setupMediaPlaybackMessageHandler(for: webView)
        applyMuteState(to: webView, reason: "bindWebView")
    }

    private func configureNavigationDelegateCallbacks() {
        guard let navigationDelegate else { return }
        let boundWebViewInstanceID = webViewInstanceID
        let boundHistoryStore = historyStore

        navigationDelegate.didStartProvisionalNavigation = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = true
                self.refreshBackgroundAppearance()
                self.applyMuteState(to: webView, reason: "navigationStart")
            }
        }
        navigationDelegate.didCommit = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                // Reset playback tracking only once the new top-level document has
                // actually replaced the old one. Resetting earlier (on provisional
                // start) would drop a still-playing page's frames if the
                // navigation then fails or is canceled, letting a playing pane be
                // discarded. didCommit does not fire for same-document (pushState)
                // navigations, so a persisting SPA video keeps its frame id.
                self.resetMediaPlaybackTracking()
                self.publishCommittedURL(from: webView)
                self.applyMuteState(to: webView, reason: "navigationCommit")
            }
        }
        navigationDelegate.didFinish = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                self.publishCommittedURL(from: webView)
                self.applyMuteState(to: webView, reason: "navigationFinish")
                self.realignRestoredSessionHistoryToLiveCurrentIfPossible()
                boundHistoryStore.recordVisit(url: webView.url, title: webView.title)
                self.refreshFavicon(from: webView)
                // Keep find-in-page open through load completion and refresh matches for the new DOM.
                self.restoreFindStateAfterNavigation(replaySearch: true)
            }
        }
        navigationDelegate.didFailNavigation = { [weak self] failedWebView, failedURL in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(failedWebView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                if let url = URL(string: failedURL) {
                    self.currentURL = Self.remoteProxyDisplayURL(for: url) ?? url
                }
                // Clear stale title/favicon from the previous page so the tab
                // shows the failed URL instead of the old page's branding.
                self.pageTitle = failedURL.isEmpty ? "" : failedURL
                self.faviconPNGData = nil
                self.lastFaviconURLString = nil
                self.applyMuteState(to: failedWebView, reason: "navigationFail")
                // Keep find-in-page open and clear stale counters on failed loads.
                self.restoreFindStateAfterNavigation(replaySearch: false)
            }
        }
        navigationDelegate.didCancelProvisionalNavigation = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: boundWebViewInstanceID) else { return }
                self.isMainFrameProvisionalNavigationActive = false
                self.navigationDelegate?.lastAttemptedURL = nil
                self.refreshBackgroundAppearance()
            }
        }
    }

    private func publishCommittedURL(from webView: WKWebView) {
        currentURL = Self.remoteProxyDisplayURL(for: webView.url)
        navigationDelegate?.lastAttemptedURL = nil
        refreshBackgroundAppearance()
        GlobalSearchCoordinator.shared.captureBrowserPanel(self)
    }

    private func isCurrentWebView(_ candidate: WKWebView, instanceID: UUID? = nil) -> Bool {
        guard candidate === webView else { return false }
        guard let instanceID else { return true }
        return instanceID == webViewInstanceID
    }

    /// Tracks whether the process-once browser defaults bootstrap has run.
    private static var hasBootstrappedBrowserDefaults = false

    /// Registers browser fallback defaults and normalizes any legacy/out-of-range
    /// stored settings to their canonical form, exactly once per process.
    ///
    /// This is app-once work, not per-view work. Keeping it out of
    /// `BrowserPanelView.onAppear` is what fixes the issue #5303 render loop:
    /// `.onAppear` can re-fire on every CoreAnimation commit for a portal-hosted
    /// pane, and a view-scoped `@State` guard resets whenever the view changes
    /// identity (a remount re-runs it). A process-scoped guard runs the work once
    /// regardless of how many panels or view instances come and go.
    ///
    /// Always targets `UserDefaults.standard`: the guard is process-wide, so an
    /// injectable suite here would silently no-op for every caller after the first.
    /// Tests exercise ``normalizeBrowserDefaults(defaults:)`` directly with a
    /// scratch suite instead.
    static func bootstrapBrowserDefaultsIfNeeded() {
        guard !hasBootstrappedBrowserDefaults else { return }
        hasBootstrappedBrowserDefaults = true
        normalizeBrowserDefaults(defaults: .standard)
    }

    /// Registers fallback defaults and writes back canonical values for any stored
    /// browser setting whose raw value is legacy or out of range.
    ///
    /// Pure with respect to the injected `defaults`, so it is unit-testable against
    /// a scratch `UserDefaults(suiteName:)` without touching `UserDefaults.standard`.
    static func normalizeBrowserDefaults(defaults: UserDefaults) {
        defaults.register(defaults: [
            BrowserSearchSettingsStore.searchEngineKey: BrowserSearchSettingsStore.defaultSearchEngine.rawValue,
            BrowserSearchSettingsStore.customSearchEngineNameKey: BrowserSearchSettingsStore.defaultCustomSearchEngineName,
            BrowserSearchSettingsStore.customSearchEngineURLTemplateKey: BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate,
            BrowserSearchSettingsStore.searchSuggestionsEnabledKey: BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled,
            BrowserToolbarAccessorySpacingDebugSettings.key: BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing,
            BrowserProfilePopoverDebugSettings.horizontalPaddingKey: BrowserProfilePopoverDebugSettings.defaultHorizontalPadding,
            BrowserProfilePopoverDebugSettings.verticalPaddingKey: BrowserProfilePopoverDebugSettings.defaultVerticalPadding,
            BrowserThemeSettings.modeKey: BrowserThemeSettings.defaultMode.rawValue,
        ])

        let resolvedThemeMode = BrowserThemeSettings.mode(defaults: defaults)
        let currentThemeRaw = defaults.string(forKey: BrowserThemeSettings.modeKey)
            ?? BrowserThemeSettings.defaultMode.rawValue
        if currentThemeRaw != resolvedThemeMode.rawValue {
            defaults.set(resolvedThemeMode.rawValue, forKey: BrowserThemeSettings.modeKey)
        }

        let resolvedHintVariant = BrowserImportHintSettings.variant(defaults: defaults)
        let currentHintRaw = defaults.string(forKey: BrowserImportHintSettings.variantKey)
            ?? BrowserImportHintSettings.defaultVariant.rawValue
        if currentHintRaw != resolvedHintVariant.rawValue {
            defaults.set(resolvedHintVariant.rawValue, forKey: BrowserImportHintSettings.variantKey)
        }

        let resolvedToolbarSpacing = BrowserToolbarAccessorySpacingDebugSettings.current(defaults: defaults)
        let currentToolbarSpacing = (defaults.object(forKey: BrowserToolbarAccessorySpacingDebugSettings.key) as? Int)
            ?? BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
        if currentToolbarSpacing != resolvedToolbarSpacing {
            defaults.set(resolvedToolbarSpacing, forKey: BrowserToolbarAccessorySpacingDebugSettings.key)
        }

        let resolvedHorizontalPadding = BrowserProfilePopoverDebugSettings.currentHorizontalPadding(defaults: defaults)
        let currentHorizontalPadding = (defaults.object(forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
        if currentHorizontalPadding != resolvedHorizontalPadding {
            defaults.set(resolvedHorizontalPadding, forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
        }

        let resolvedVerticalPadding = BrowserProfilePopoverDebugSettings.currentVerticalPadding(defaults: defaults)
        let currentVerticalPadding = (defaults.object(forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverDebugSettings.defaultVerticalPadding
        if currentVerticalPadding != resolvedVerticalPadding {
            defaults.set(resolvedVerticalPadding, forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)
        }
    }

    init(
        workspaceId: UUID,
        profileID: UUID? = nil,
        initialURL: URL? = nil,
        initialRequest: URLRequest? = nil,
        renderInitialNavigation: Bool = true,
        preloadInitialNavigationInBackground: Bool = false,
        bypassInsecureHTTPHostOnce: String? = nil,
        omnibarVisible: Bool = true,
        transparentBackground: Bool = false,
        proxyEndpoint: BrowserProxyEndpoint? = nil,
        bypassRemoteProxy: Bool = false,
        isRemoteWorkspace: Bool = false,
        remoteWebsiteDataStoreIdentifier: UUID? = nil
    ) {
        // Register fallback defaults and normalize legacy/out-of-range settings once
        // per process, before any setting is read below or by the SwiftUI view.
        Self.bootstrapBrowserDefaultsIfNeeded()
        self.id = UUID()
        self.workspaceId = workspaceId
        let requestedProfileID = profileID ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        let resolvedProfileID = BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
        self.profileID = resolvedProfileID
        self.historyStore = BrowserProfileStore.shared.historyStore(for: resolvedProfileID)
        self.insecureHTTPBypassHostOnce = BrowserInsecureHTTPSettings.normalizeHost(bypassInsecureHTTPHostOnce ?? "")
        self.bypassesRemoteWorkspaceProxy = bypassRemoteProxy
        self.remoteProxyEndpoint = bypassRemoteProxy ? nil : proxyEndpoint
        self.usesRemoteWorkspaceProxy = isRemoteWorkspace && !bypassRemoteProxy
        self.browserThemeMode = BrowserThemeSettings.mode()
        self.shouldPreloadInitialNavigationInBackground = preloadInitialNavigationInBackground
        self.isOmnibarVisible = omnibarVisible
        self.usesTransparentBackground = transparentBackground
        self.websiteDataStore = isRemoteWorkspace
            ? WKWebsiteDataStore(forIdentifier: remoteWebsiteDataStoreIdentifier ?? workspaceId)
            : BrowserProfileStore.shared.websiteDataStore(for: resolvedProfileID)
        let webView = Self.makeWebView(
            profileID: resolvedProfileID,
            websiteDataStore: websiteDataStore
        )
        self.webView = webView
        self.insecureHTTPAlertFactory = { NSAlert() }
        hiddenWebViewDiscardManager.delegate = self
        applyProxyConfigurationIfAvailable()
        BrowserProfileStore.shared.noteUsed(resolvedProfileID)

        // Set up navigation delegate
        let navDelegate = BrowserNavigationDelegate()
        navDelegate.openInNewTab = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        navDelegate.requestNavigation = { [weak self] request, intent in
            self?.requestNavigation(request, intent: intent)
        }
        navDelegate.presentAlert = { [weak self] alert, webView, completion, cancel in
            guard let self else {
                cancel()
                return
            }
            self.presentBrowserAlert(alert, in: webView, completion: completion, cancel: cancel)
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
        browserUIDelegate.presentAlert = { [weak self] alert, webView, completion, cancel in
            guard let self else {
                cancel()
                return
            }
            self.presentBrowserAlert(alert, in: webView, completion: completion, cancel: cancel)
        }
        browserUIDelegate.openPopup = { [weak self] configuration, windowFeatures in
            self?.createFloatingPopup(configuration: configuration, windowFeatures: windowFeatures)
        }
        browserUIDelegate.closeRequested = { [weak self] closedWebView in
            guard let self, self.isCurrentWebView(closedWebView) else { return }
#if DEBUG
            cmuxDebugLog("browser.webViewDidClose panel=\(self.id.uuidString.prefix(5))")
#endif
            self.webViewDidRequestClose?()
        }
        self.uiDelegate = browserUIDelegate

        bindWebView(webView)
        installDetachedDeveloperToolsWindowCloseObserver()
        installHiddenWebViewDiscardPolicyObserver()
        applyBrowserThemeModeIfNeeded()
        ReactGrabScriptLoader.prefetch()
        insecureHTTPAlertWindowProvider = { [weak self] in
            if let self, let window = browserInteractiveModalHostWindow(for: self.webView) {
                return window
            }
            return browserFallbackInteractiveModalHostWindow()
        }

        if let initialRequest {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
            currentURL = initialRequest.url
            shouldRenderWebView = renderInitialNavigation
            guard renderInitialNavigation else { return }
            if let url = initialRequest.url,
               insecureHTTPBypassHostOnce == nil,
               shouldBlockInsecureHTTPNavigation(to: url) {
                presentInsecureHTTPAlert(
                    for: initialRequest,
                    intent: .currentTab,
                    recordTypedNavigation: false
                )
            } else {
                navigateWithoutInsecureHTTPPrompt(
                    request: initialRequest,
                    recordTypedNavigation: false
                )
            }
        } else if let url = initialURL {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
            currentURL = url
            shouldRenderWebView = renderInitialNavigation
            guard renderInitialNavigation else { return }
            navigate(to: url)
        }
    }

    @discardableResult
    private func ensureBackgroundPreloadHostIfNeeded(reason: String) -> Bool {
        if let preloadWindow = backgroundPreloadWindow {
            guard webView.window == nil,
                  webView.superview == nil,
                  let contentView = preloadWindow.contentView else {
                return false
            }
            webView.frame = contentView.bounds
            webView.autoresizingMask = [.width, .height]
            contentView.addSubview(webView)
            return true
        }

        guard webView.window == nil else { return false }
        guard webView.superview == nil else { return false }

        let frame = NSRect(x: -10_000, y: -10_000, width: 800, height: 600)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserBackgroundPreload")
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: frame)
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        window.contentView = contentView
        backgroundPreloadWindow = window
        window.orderFrontRegardless()

#if DEBUG
        cmuxDebugLog(
            "browser.backgroundPreload.host.create panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason)"
        )
#endif
        return true
    }

    private func shouldDeferPromptUntilInteractiveHost(for webView: WKWebView) -> Bool {
        if shouldPreloadInitialNavigationInBackground {
            return true
        }
        guard let preloadWindow = backgroundPreloadWindow else { return false }
        let attachedWindow = webView.window
        return attachedWindow == nil || attachedWindow === preloadWindow
    }

    private func presentBrowserAlert(
        _ alert: NSAlert,
        in webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        cancel: @escaping () -> Void
    ) {
        if let window = browserInteractiveModalHostWindow(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }

        guard shouldDeferPromptUntilInteractiveHost(for: webView) else {
            browserPresentAlert(alert, in: webView, completion: completion, cancel: cancel)
            return
        }

        pendingInteractiveBrowserPrompts.append(
            PendingInteractiveBrowserPrompt(
                present: { sheetWindow, didFinish in
                    alert.beginSheetModal(for: sheetWindow) { response in
                        completion(response)
                        didFinish()
                    }
                },
                cancel: cancel
            )
        )

#if DEBUG
        cmuxDebugLog(
            "browser.prompt.queue panel=\(id.uuidString.prefix(5)) " +
            "pending=\(pendingInteractiveBrowserPrompts.count)"
        )
#endif
    }

    private func drainPendingInteractiveBrowserPromptsIfPossible(reason: String) {
        guard !isPresentingPendingInteractiveBrowserPrompt else { return }
        guard !pendingInteractiveBrowserPrompts.isEmpty else { return }
        guard let window = browserInteractiveModalHostWindow(for: webView) else { return }

        let prompt = pendingInteractiveBrowserPrompts.removeFirst()
        isPresentingPendingInteractiveBrowserPrompt = true

#if DEBUG
        cmuxDebugLog(
            "browser.prompt.drain panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) remaining=\(pendingInteractiveBrowserPrompts.count)"
        )
#endif

        prompt.present(window) { [weak self] in
            guard let self else { return }
            self.isPresentingPendingInteractiveBrowserPrompt = false
            self.drainPendingInteractiveBrowserPromptsIfPossible(reason: "\(reason).next")
        }
    }

    private func cancelPendingInteractiveBrowserPrompts(reason: String) {
        guard !pendingInteractiveBrowserPrompts.isEmpty else { return }
        let prompts = pendingInteractiveBrowserPrompts
        pendingInteractiveBrowserPrompts.removeAll()
        isPresentingPendingInteractiveBrowserPrompt = false

#if DEBUG
        cmuxDebugLog(
            "browser.prompt.cancel panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) count=\(prompts.count)"
        )
#endif

        prompts.forEach { $0.cancel() }
    }

    func releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: String) {
        guard let preloadWindow = backgroundPreloadWindow else { return }
        guard let attachedWindow = webView.window else { return }
        guard attachedWindow !== preloadWindow else { return }
        closeBackgroundPreloadHost(reason: reason)
        drainPendingInteractiveBrowserPromptsIfPossible(reason: reason)
    }

    private func closeBackgroundPreloadHost(reason: String) {
        guard let preloadWindow = backgroundPreloadWindow else { return }
        backgroundPreloadWindow = nil
        preloadWindow.contentView = nil
        preloadWindow.close()
#if DEBUG
        cmuxDebugLog(
            "browser.backgroundPreload.host.close panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason)"
        )
#endif
    }

    func setRemoteProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        guard !bypassesRemoteWorkspaceProxy else { return }
        guard remoteProxyEndpoint != endpoint else { return }
        remoteProxyEndpoint = endpoint
        applyProxyConfigurationIfAvailable()
        resumePendingRemoteNavigationIfNeeded()
    }

    func setRemoteWorkspaceStatus(_ status: BrowserRemoteWorkspaceStatus?) {
        guard remoteWorkspaceStatus != status else { return }
        remoteWorkspaceStatus = status
    }

    private func applyProxyConfigurationIfAvailable() {
        guard #available(macOS 14.0, *) else { return }

        let store = webView.configuration.websiteDataStore
        guard let endpoint = remoteProxyEndpoint else {
            // Local panes mirror an active system proxy with loopback excluded
            // (#5888); remote panes keep [] while their endpoint is pending/lost.
            store.proxyConfigurations = usesRemoteWorkspaceProxy
                ? [] : BrowserSystemProxyMirror.currentProxyConfigurations()
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
            let wasDownloading = self.isDownloading
            self.activeDownloadCount += 1
            self.isDownloading = self.activeDownloadCount > 0
            if !wasDownloading && self.isDownloading {
                self.reevaluateHiddenWebViewDiscardScheduling(reason: "download.started")
            }
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
            if !self.isDownloading {
                self.scheduleHiddenWebViewDiscardIfNeeded(reason: "download.finished")
            }
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
        usesRemoteWorkspaceProxy = isRemoteWorkspace && !bypassesRemoteWorkspaceProxy
        let targetStore = isRemoteWorkspace
            ? WKWebsiteDataStore(forIdentifier: remoteWebsiteDataStoreIdentifier ?? newWorkspaceId)
            : BrowserProfileStore.shared.websiteDataStore(for: profileID)
        let needsStoreSwap = webView.configuration.websiteDataStore !== targetStore
        websiteDataStore = targetStore
        remoteProxyEndpoint = bypassesRemoteWorkspaceProxy ? nil : proxyEndpoint
        remoteWorkspaceStatus = remoteStatus
        if needsStoreSwap {
            replaceWebViewPreservingState(
                from: webView,
                websiteDataStore: targetStore,
                reason: "workspace_reattach"
            )
        }
        applyProxyConfigurationIfAvailable()
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
        clearWebContentTerminationRecovery()
        clearBrowserFocusMode(reason: "profileSwitch")
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        cancelPendingInteractiveBrowserPrompts(reason: "profileSwitch")
        closeBackgroundPreloadHost(reason: "profileSwitch")
        BrowserWindowPortalRegistry.detach(webView: previousWebView)
        previousWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
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
        resetWebViewLifecycleMetadata(resetVisibility: false)
        webView = replacement
        currentURL = restoreURL
        shouldRenderWebView = wasRenderable
        refreshWebViewLifecycleState()

        bindWebView(replacement)
        applyProxyConfigurationIfAvailable()
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

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken &+= 1
    }

    func sessionNavigationHistorySnapshot() -> (
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String]
    ) {
        realignRestoredSessionHistoryToLiveCurrentIfPossible()

        let nativeBack = webView.backForwardList.backList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }
        let nativeForward = webView.backForwardList.forwardList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }

        if usesRestoredSessionHistory {
            let back = restoredBackHistoryStack.compactMap { Self.serializableSessionHistoryURLString($0) }
            // `restoredForwardHistoryStack` stores nearest-forward entries at the end.
            let restoredForward = restoredForwardHistoryStack.reversed().compactMap {
                Self.serializableSessionHistoryURLString($0)
            }

            if isLiveSessionHistoryAlignedWithRestoredCurrent {
                return (
                    back,
                    restoredForward.isEmpty ? nativeForward : restoredForward
                )
            }

            return (back + nativeBack, nativeForward)
        }

        return (nativeBack, nativeForward)
    }

    private func resolvedLiveSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           Self.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           Self.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return nil
    }

    private var isLiveSessionHistoryAlignedWithRestoredCurrent: Bool {
        let liveCurrent = Self.serializableSessionHistoryURLString(resolvedLiveSessionHistoryURL())
        let restoredCurrent = Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL)
        guard let liveCurrent, let restoredCurrent else { return true }
        return liveCurrent == restoredCurrent
    }

    private func realignRestoredSessionHistoryToLiveCurrentIfPossible() {
        guard usesRestoredSessionHistory else { return }
        guard let liveCurrent = resolvedLiveSessionHistoryURL(),
              let liveCurrentString = Self.serializableSessionHistoryURLString(liveCurrent) else {
            return
        }
        guard Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL) != liveCurrentString else {
            return
        }

        let restoredBack = restoredBackHistoryStack.compactMap { Self.serializableSessionHistoryURLString($0) }
        let restoredForward = restoredForwardHistoryStack.reversed().compactMap {
            Self.serializableSessionHistoryURLString($0)
        }
        let restoredCurrent = Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL)

        if let backIndex = restoredBack.lastIndex(of: liveCurrentString) {
            let newBack = Array(restoredBack[..<backIndex])
            var newForward = Array(restoredBack[(backIndex + 1)...])
            if let restoredCurrent {
                newForward.append(restoredCurrent)
            }
            newForward.append(contentsOf: restoredForward)

            restoredBackHistoryStack = Self.sanitizedSessionHistoryURLs(newBack)
            restoredForwardHistoryStack = Array(Self.sanitizedSessionHistoryURLs(newForward).reversed())
            restoredHistoryCurrentURL = liveCurrent
            refreshNavigationAvailability()
            return
        }

        if let forwardIndex = restoredForward.firstIndex(of: liveCurrentString) {
            var newBack = restoredBack
            if let restoredCurrent {
                newBack.append(restoredCurrent)
            }
            newBack.append(contentsOf: restoredForward[..<forwardIndex])
            let newForward = Array(restoredForward[(forwardIndex + 1)...])

            restoredBackHistoryStack = Self.sanitizedSessionHistoryURLs(newBack)
            restoredForwardHistoryStack = Array(Self.sanitizedSessionHistoryURLs(newForward).reversed())
            restoredHistoryCurrentURL = liveCurrent
            refreshNavigationAvailability()
            return
        }

        guard !restoredForwardHistoryStack.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "browser.history.restore.forward.clear panel=\(id.uuidString.prefix(5)) " +
            "current=\(liveCurrentString)"
        )
#endif
        restoredForwardHistoryStack.removeAll(keepingCapacity: false)
        refreshNavigationAvailability()
    }

    func restoreSessionNavigationHistory(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) {
        let restoredBack = Self.sanitizedSessionHistoryURLs(backHistoryURLStrings)
        let restoredForward = Self.sanitizedSessionHistoryURLs(forwardHistoryURLStrings)
        let restoredCurrent = Self.sanitizedSessionHistoryURL(currentURLString)
        guard !restoredBack.isEmpty || !restoredForward.isEmpty || restoredCurrent != nil else { return }

        usesRestoredSessionHistory = true
        restoredBackHistoryStack = restoredBack
        // Store nearest-forward entries at the end to make stack pop operations trivial.
        restoredForwardHistoryStack = Array(restoredForward.reversed())
        restoredHistoryCurrentURL = restoredCurrent
        refreshNavigationAvailability()
    }

    func restoreSessionSnapshot(_ snapshot: SessionBrowserPanelSnapshot) {
        // Diff viewer surfaces re-register their token from the on-disk manifest
        // and navigate via the app-owned custom scheme, so they restore even
        // though the local HTTP server that originally served them is gone.
        if let token = snapshot.diffViewerToken,
           let requestPath = snapshot.diffViewerRequestPath,
           CmuxDiffViewerURLSchemeHandler.shared.registerFromManifest(token: token),
           let diffURL = CmuxDiffViewerURLSchemeHandler.diffViewerURL(token: token, requestPath: requestPath) {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(snapshot.shouldRenderWebView)
            setMuted(snapshot.isMuted)
            setOmnibarVisible(snapshot.omnibarVisible ?? false)
            currentURL = diffURL
            let shouldRenderRestoredWebView = snapshot.shouldRenderWebView && BrowserAvailabilitySettings.isEnabled()
            shouldRenderWebView = shouldRenderRestoredWebView
            guard shouldRenderRestoredWebView else {
                refreshNavigationAvailability()
                return
            }
            navigateWithoutInsecureHTTPPrompt(
                to: diffURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: false
            )
            return
        }

        let restoredURL = Self.sanitizedSessionHistoryURL(snapshot.urlString)
        let shouldRenderRestoredWebView = snapshot.shouldRenderWebView && BrowserAvailabilitySettings.isEnabled()
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(snapshot.shouldRenderWebView)
        setMuted(snapshot.isMuted)
        setOmnibarVisible(snapshot.omnibarVisible ?? true)

        restoreSessionNavigationHistory(
            backHistoryURLStrings: snapshot.backHistoryURLStrings ?? [],
            forwardHistoryURLStrings: snapshot.forwardHistoryURLStrings ?? [],
            currentURLString: snapshot.urlString
        )

        currentURL = restoredURL
        shouldRenderWebView = shouldRenderRestoredWebView

        guard shouldRenderRestoredWebView, let restoredURL else {
            refreshNavigationAvailability()
            return
        }

        navigateWithoutInsecureHTTPPrompt(
            to: restoredURL,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true
        )
    }

    func shouldRenderWebViewForSessionSnapshot() -> Bool {
        // Diff viewer URLs are "temporary" so `preferredURLStringForSessionSnapshot()`
        // is nil, but they are restorable via their token, so honor their render
        // intent too (otherwise a restored diff surface never navigates).
        guard preferredURLStringForSessionSnapshot() != nil || diffViewerSessionComponents() != nil else {
            return false
        }
        return hiddenWebViewDiscardManager.restoredSessionShouldRenderWebView ?? shouldRenderWebView
    }

    func shouldPersistSessionSnapshot() -> Bool {
        // Diff viewer surfaces are otherwise treated as temporary. Persist them
        // only when they can actually be restored via the custom scheme (a
        // local-only, non-pending manifest); otherwise persisting would leave a
        // blank panel on restart with no URL to fall back to.
        if let components = diffViewerSessionComponents() {
            return CmuxDiffViewerURLSchemeHandler.shared.diffViewerRestorable(
                token: components.token,
                requestPath: components.requestPath
            )
        }
        guard !Self.isTemporarySessionHistoryURL(webView.url),
              !Self.isTemporarySessionHistoryURL(currentURL),
              !Self.isTemporarySessionHistoryURL(restoredHistoryCurrentURL) else {
            return false
        }
        return true
    }

    /// Whether this surface is transparent internal cmux UI, for the session
    /// snapshot (so it restores transparent rather than opaque).
    var sessionSnapshotTransparentBackground: Bool {
        usesTransparentBackground
    }

    /// The diff viewer `(token, requestPath)` for the live URL, if this surface
    /// is currently showing a diff viewer; used to persist + restore it.
    func diffViewerSessionComponents() -> (token: String, requestPath: String)? {
        CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: webView.url)
            ?? CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: currentURL)
    }

    func preferredURLStringForSessionSnapshot() -> String? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           let value = Self.serializableSessionHistoryURLString(webViewURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }

    private func setupObservers(for webView: WKWebView) {
        let observedWebViewInstanceID = webViewInstanceID

        // URL changes
        let urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
            let observedURL = change.newValue ?? webView.url
            MainActor.assumeIsolated {
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                guard !self.isMainFrameProvisionalNavigationActive else { return }
                self.currentURL = Self.remoteProxyDisplayURL(for: observedURL)
                self.refreshBackgroundAppearance()
                GlobalSearchCoordinator.shared.captureBrowserPanel(self)
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
                GlobalSearchCoordinator.shared.captureBrowserPanel(self)
            }
        }
        webViewObservers.append(titleObserver)

        // Loading state
        // Capture the KVO-provided value at observation time rather than reading
        // webView.isLoading inside the deferred Task. For fast navigations (e.g.
        // back-forward cache), isLoading can flip true→false before the first Task
        // runs, causing handleWebViewLoadingChanged(true) to be missed entirely.
        // That skips favicon/loading-state cleanup and leaves stale icons visible.
        let loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
            let newValue = change.newValue ?? webView.isLoading
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.handleWebViewLoadingChanged(newValue)
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

        let fullscreenObserver = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] webView, _ in
            let isElementFullscreenActive = webView.cmuxIsElementFullscreenActiveOrTransitioning
            let fullscreenState = webView.fullscreenState
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                let didChangeFullscreenBlocker = self.isElementFullscreenActive != isElementFullscreenActive
                self.isElementFullscreenActive = isElementFullscreenActive
                if didChangeFullscreenBlocker {
                    self.reevaluateHiddenWebViewDiscardScheduling(reason: "fullscreen_changed")
                }
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "fullscreenStateChanged"
                )
#if DEBUG
                cmuxDebugLog(
                    "browser.fullscreen.state panel=\(self.id.uuidString.prefix(5)) " +
                    "web=\(ObjectIdentifier(webView)) state=\(String(describing: fullscreenState)) " +
                    "active=\(isElementFullscreenActive ? 1 : 0)"
                )
#endif
            }
        }
        webViewObservers.append(fullscreenObserver)

        let cameraCaptureObserver = webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.reevaluateHiddenWebViewDiscardScheduling(reason: "media_capture_changed")
            }
        }
        webViewObservers.append(cameraCaptureObserver)

        let microphoneCaptureObserver = webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                guard let self, self.isCurrentWebView(webView, instanceID: observedWebViewInstanceID) else { return }
                self.reevaluateHiddenWebViewDiscardScheduling(reason: "media_capture_changed")
            }
        }
        webViewObservers.append(microphoneCaptureObserver)

        NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)
            .sink { [weak self] notification in
                guard let self else { return }
                self.applyWebViewBackground(color: GhosttyBackgroundTheme.color(from: notification))
            }
            .store(in: &webViewCancellables)

        // Keep the local-workspace system-proxy mirror fresh when the user
        // toggles a global proxy or switches network locations mid-session.
        NotificationCenter.default.publisher(for: .browserSystemProxySettingsDidChange)
            .sink { [weak self] _ in self?.applyProxyConfigurationIfAvailable() }
            .store(in: &webViewCancellables)

        // Apply the configured background for the freshly bound webview (covers
        // the initial bind and every post-crash replacement).
        applyConfiguredWebViewBackground()
    }

    /// Configures the live webview's background for the current Ghostty theme.
    private func applyConfiguredWebViewBackground() {
        applyWebViewBackground(color: GhosttyBackgroundTheme.currentColor())
    }

    private func refreshBackgroundAppearance() {
        applyConfiguredWebViewBackground()
        backgroundAppearanceRevision &+= 1
    }

    /// Applies the webview background for a given terminal theme color.
    ///
    /// When Ghostty transparency/glass makes the window root own the terminal
    /// backdrop, clear the browser's native fill for blank pages. Real websites
    /// keep WebKit's background drawing so pages without their own CSS
    /// background remain readable.
    private func applyWebViewBackground(color: NSColor) {
        if !drawsConfiguredWebViewBackgroundForCurrentPage() {
            webView.wantsLayer = true
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
            webView.layer?.isOpaque = false
            webView.layer?.backgroundColor = NSColor.clear.cgColor
            portalAnchorView.wantsLayer = true
            portalAnchorView.layer?.isOpaque = false
            portalAnchorView.layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        if usesTransparentBackground {
            // Transparent-background internal surface (the diff viewer, and future
            // app-bundled cmux panels) on an OPAQUE theme. The page keeps its body
            // transparent, and the pane behind it is a plain gray window backdrop,
            // not the terminal color. With WebKit drawing its own background the
            // webview flashes white during navigation (blank document) and any
            // transparent page region (loading skeleton, empty/error state) shows
            // gray. So instead of letting WebKit draw, paint the webview and its
            // portal anchor with the theme color directly (clear-draw + themed
            // layer, exactly like the markdown and agent-session renderers). That
            // makes the blank webview, the brief pane-reveal frame, and every
            // transparent page region render the terminal color from the first
            // frame. Tracks live theme changes via this same call.
            webView.wantsLayer = true
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = color
            webView.layer?.isOpaque = color.alphaComponent >= 0.999
            webView.layer?.backgroundColor = color.cgColor
            portalAnchorView.wantsLayer = true
            portalAnchorView.layer?.isOpaque = color.alphaComponent >= 0.999
            portalAnchorView.layer?.backgroundColor = color.cgColor
            return
        }
        // Real website on an opaque theme: keep WebKit drawing its own background
        // so pages without their own CSS background remain readable. (Restores
        // opaque drawing in case a transparent theme previously made this webview
        // clear before the user switched to an opaque theme.)
        webView.setValue(true, forKey: "drawsBackground")
        webView.layer?.isOpaque = color.alphaComponent >= 0.999
        webView.layer?.backgroundColor = nil
        webView.underPageBackgroundColor = color
        portalAnchorView.wantsLayer = true
        portalAnchorView.layer?.isOpaque = false
        portalAnchorView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func drawsConfiguredWebViewBackgroundForCurrentPage() -> Bool {
        Self.drawsConfiguredWebViewBackground(
            isBlankPage: isShowingBlankBrowserPage,
            usesTransparentBackground: usesTransparentBackground
        )
    }

    /// Whether browser native/SwiftUI fills should draw over the window root
    /// backdrop. Mirrors terminal/markdown panel background decisions.
    static func drawsConfiguredWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false
    ) -> Bool {
        drawsWebViewBackground(
            isBlankPage: isBlankPage,
            usesTransparentBackground: usesTransparentBackground,
            opacity: GhosttyApp.shared.defaultBackgroundOpacity,
            usesGhosttyGlassStyle: GhosttyApp.shared.defaultBackgroundBlur.isMacOSGlassStyle,
            usesTransparentWindow: WindowBackgroundComposition.policy
                .shouldUseTransparentBackgroundWindow(glassEffectAvailable: WindowGlassEffect.isAvailable)
        )
    }

    nonisolated static func isBlankBrowserPageURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.caseInsensitiveCompare("about:blank") == .orderedSame
    }

    nonisolated static func isBlankBrowserPage(
        liveURL: URL?,
        currentURL: URL?,
        pendingNavigationURL: URL?,
        isMainFrameProvisionalNavigationActive: Bool
    ) -> Bool {
        if isMainFrameProvisionalNavigationActive,
           !isBlankBrowserPageURL(pendingNavigationURL) {
            return false
        }
        if !isBlankBrowserPageURL(pendingNavigationURL),
           isBlankBrowserPageURL(liveURL),
           isBlankBrowserPageURL(currentURL) {
            return false
        }
        return isBlankBrowserPageURL(liveURL) && isBlankBrowserPageURL(currentURL)
    }

    nonisolated static func drawsWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false,
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        if usesTransparentBackground {
            return drawsWebViewBackground(
                opacity: opacity,
                usesGhosttyGlassStyle: usesGhosttyGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        }
        guard isBlankPage else { return true }
        return drawsWebViewBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }

    nonisolated static func drawsWebViewBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        !PanelAppearance.shouldUseClearContentBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }

    private func replaceWebViewAfterContentProcessTermination(for terminatedWebView: WKWebView) {
        replaceWebViewPreservingState(
            from: terminatedWebView,
            websiteDataStore: websiteDataStore,
            reason: "webcontent_process_terminated",
            waitForManualRecovery: true
        )
    }

    private func replaceWebViewPreservingState(
        from oldWebView: WKWebView,
        websiteDataStore: WKWebsiteDataStore,
        reason: String,
        waitForManualRecovery: Bool = false
    ) {
        guard oldWebView === webView else { return }

        let wasRenderable = shouldRenderWebView
        let attemptedURL = Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)
            ?? navigationDelegate?.lastAttemptedURL
        let liveURL = Self.remoteProxyDisplayURL(for: oldWebView.url)
            ?? currentURL
        let restoreURL = (isMainFrameProvisionalNavigationActive ? attemptedURL : nil)
            ?? liveURL
            ?? attemptedURL
            ?? resolvedCurrentSessionHistoryURL()
        let restoreURLString = restoreURL?.absoluteString
        let hasRecoveryTarget = restoreURLString != nil && restoreURLString != blankURLString
        let shouldRestoreURL = wasRenderable && hasRecoveryTarget
        let shouldShowManualRecovery = waitForManualRecovery && wasRenderable && hasRecoveryTarget
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar()
        let desiredZoom = max(minPageZoom, min(maxPageZoom, oldWebView.pageZoom))
        let restoreDevTools = preferredDeveloperToolsVisible

#if DEBUG
        cmuxDebugLog(
            "browser.webview.replace.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "renderable=\(wasRenderable ? 1 : 0) restoreURL=\(restoreURLString ?? "nil") " +
            "restoreHistoryBack=\(history.backHistoryURLStrings.count) " +
            "restoreHistoryForward=\(history.forwardHistoryURLStrings.count)"
        )
#endif

        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        clearBrowserFocusMode(reason: reason)
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil
        isLoading = false
        estimatedProgress = 0
        cancelPendingInteractiveBrowserPrompts(reason: reason)
        closeBackgroundPreloadHost(reason: reason)
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
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
        resetWebViewLifecycleMetadata(resetVisibility: false)
        webView = replacement
        shouldRenderWebView = wasRenderable
        refreshWebViewLifecycleState()

        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()

        if !history.backHistoryURLStrings.isEmpty || !history.forwardHistoryURLStrings.isEmpty {
            restoreSessionNavigationHistory(
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                currentURLString: historyCurrentURL
            )
        }

        if shouldShowManualRecovery, let restoreURL {
            pendingWebContentRecoveryURL = restoreURL
            hasRecoverableWebContentTermination = true
            refreshNavigationAvailability()
        } else {
            clearWebContentTerminationRecovery()
            if shouldRestoreURL, let restoreURL {
                navigateWithoutInsecureHTTPPrompt(
                    to: restoreURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
            } else {
                refreshNavigationAvailability()
            }
        }

        if restoreDevTools {
            requestDeveloperToolsRefreshAfterNextAttach(reason: reason)
        }

#if DEBUG
        cmuxDebugLog(
            "browser.webview.replace.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "instance=\(webViewInstanceID.uuidString.prefix(6)) " +
            "restoreURL=\(restoreURLString ?? "nil") shouldRestore=\(shouldRestoreURL ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func recoverTerminatedWebContent(reason: String = "manual") -> Bool {
        guard hasRecoverableWebContentTermination else { return false }
        let recoveryURL = pendingWebContentRecoveryURL
        clearWebContentTerminationRecovery()
#if DEBUG
        cmuxDebugLog(
            "browser.webcontent.recover panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) url=\(recoveryURL?.absoluteString ?? "nil")"
        )
#endif
        guard let recoveryURL else {
            refreshNavigationAvailability()
            return true
        }
        navigateWithoutInsecureHTTPPrompt(
            to: recoveryURL,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true
        )
        return true
    }

    private func clearWebContentTerminationRecovery() {
        pendingWebContentRecoveryURL = nil
        hasRecoverableWebContentTermination = false
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

    @discardableResult
    func requestExplicitWebViewFocus() -> Bool {
        // Programmatic WebView focus should win over stale omnibar focus state, especially
        // after workspace switches where the blank-page omnibar auto-focus can re-trigger.
        endSuppressWebViewFocusForAddressBar()
        clearWebViewFocusSuppression()
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)

        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return false }

        if Self.responderChainContains(window.firstResponder, target: webView) {
            // Prevent omnibar auto-focus from immediately stealing first responder back.
            suppressOmnibarAutofocus(for: 1.5)
            noteWebViewFocused()
            return true
        }

        guard window.makeFirstResponder(webView) else { return false }
        // Prevent omnibar auto-focus from immediately stealing first responder back.
        suppressOmnibarAutofocus(for: 1.5)
        noteWebViewFocused()

        DispatchQueue.main.async { [weak self, weak window, weak webView] in
            guard let self, let window, let webView else { return }
            guard webView.window === window else { return }
            if !Self.responderChainContains(window.firstResponder, target: webView),
               window.makeFirstResponder(webView) {
                self.suppressOmnibarAutofocus(for: 1.5)
                self.noteWebViewFocused()
            }
        }

        return true
    }

    func unfocus() {
        clearBrowserFocusMode(reason: "panelUnfocus")
        invalidateSearchFocusRequests(reason: "panelUnfocus")
        guard let window = webView.window else { return }
        if Self.responderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        cancelHiddenWebViewDiscard()
        isClosingWebViewLifecycle = true
        refreshWebViewLifecycleState()
        GlobalSearchCoordinator.shared.purgePanel(id: id)
        closeDeveloperToolsForTeardown()

        // Ensure we don't keep a hidden WKWebView (or its content view) as first responder while
        // bonsplit/SwiftUI reshuffles views during close.
        unfocus()
        cancelPendingInteractiveBrowserPrompts(reason: "close")
        closeBackgroundPreloadHost(reason: "close")

        // Snapshot first: popup close unregisters itself from popupControllers.
        let popupsToClose = popupControllers
        popupControllers.removeAll()

        // Close all owned popup windows before tearing down delegates
        for popup in popupsToClose {
            popup.closeAllChildPopups()
            popup.closePopup()
        }

        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        navigationDelegate = nil
        uiDelegate = nil
        webViewDidRequestClose = nil
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
            browserContext: popupBrowserContext,
            openerPanel: self
        )
        popupControllers.append(controller)
        reevaluateHiddenWebViewDiscardScheduling(reason: "popup_opened")
        return controller.webView
    }

    func removePopupController(_ controller: BrowserPopupWindowController) {
        popupControllers.removeAll { $0 === controller }
        reevaluateHiddenWebViewDiscardScheduling(reason: "popup_closed")
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
            cmuxDebugLog(
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

            // SPAs often inject <link rel="icon"> via JavaScript after the initial
            // HTML loads. If no link tag was found, wait briefly and retry once to
            // give client-side scripts time to add the tag.
            if discoveredURL == nil {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard self.isCurrentWebView(webView, instanceID: refreshWebViewInstanceID) else { return }
                guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
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
            }

            let fallbackURL = URL(string: "/favicon.ico", relativeTo: pageURL)
            let iconURL = discoveredURL ?? fallbackURL
            guard let iconURL else { return }
#if DEBUG
            cmuxDebugLog(
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
                cmuxDebugLog(
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
                    cmuxDebugLog(
                        "browser.favicon.fetch " +
                        "panel=\(id.uuidString.prefix(5)) " +
                        "via=proxy " +
                        "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                    )
#endif
                    (data, response) = try await remoteSession.data(for: effectiveRequest)
                } else {
#if DEBUG
                    cmuxDebugLog(
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
                cmuxDebugLog(
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
                cmuxDebugLog(
                    "browser.favicon.badResponse " +
                    "panel=\(id.uuidString.prefix(5)) " +
                    "status=\(status)"
                )
#endif
                return
            }
#if DEBUG
            cmuxDebugLog(
                "browser.favicon.response " +
                "panel=\(id.uuidString.prefix(5)) " +
                "status=\(http.statusCode) " +
                "bytes=\(data.count)"
            )
#endif

            // Use >= 2x the rendered point size so we don't upscale (blurry) on Retina.
            guard let png = Self.makeFaviconPNGData(from: data, targetPx: 32) else {
#if DEBUG
                cmuxDebugLog(
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
            cmuxDebugLog(
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
            cancelHiddenWebViewDiscard()
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
            scheduleHiddenWebViewDiscardIfNeeded(reason: "load.finished")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If loading restarted, ignore this end.
            guard self.loadingGeneration == genAtEnd else { return }
            // If WebKit is still loading, ignore.
            guard !self.webView.isLoading else { return }
            self.isLoading = false
            self.scheduleHiddenWebViewDiscardIfNeeded(reason: "load.finished")
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
        cancelHiddenWebViewDiscard()
        clearWebViewDiscardState(reason: "navigation")
        if usesRemoteWorkspaceProxy, remoteProxyEndpoint == nil {
            pendingRemoteNavigation = PendingRemoteNavigation(
                request: request,
                recordTypedNavigation: recordTypedNavigation,
                preserveRestoredSessionHistory: preserveRestoredSessionHistory
            )
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
            currentURL = Self.remoteProxyDisplayURL(for: url) ?? url
            navigationDelegate?.lastAttemptedURL = url
            refreshBackgroundAppearance()
            shouldRenderWebView = true
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
        // Resume on endpoint arrival, or directly once the pane turned local
        // (a stranded queue pins the hidden pane as non-discardable forever).
        guard remoteProxyEndpoint != nil || !usesRemoteWorkspaceProxy,
              let navigation = pendingRemoteNavigation else {
            return
        }
        guard let originalURL = navigation.request.url else {
            pendingRemoteNavigation = nil
            reevaluateHiddenWebViewDiscardScheduling(reason: "pending_remote_navigation_cleared")
            return
        }
        performNavigation(
            request: navigation.request,
            originalURL: originalURL,
            recordTypedNavigation: navigation.recordTypedNavigation,
            preserveRestoredSessionHistory: navigation.preserveRestoredSessionHistory
        )
        pendingRemoteNavigation = nil
    }

    private func performNavigation(
        request: URLRequest,
        originalURL: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool
    ) {
        cancelHiddenWebViewDiscard()
        clearWebContentTerminationRecovery()
        if !preserveRestoredSessionHistory {
            abandonRestoredSessionHistoryIfNeeded()
        }
        let effectiveRequest = remoteProxyPreparedRequest(from: request, logScope: "rewrite")
        // Some installs can end up with a legacy Chrome UA override; keep this pinned.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
        navigationDelegate?.lastAttemptedURL = originalURL
        refreshBackgroundAppearance()
        shouldRenderWebView = true
        if shouldPreloadInitialNavigationInBackground {
            shouldPreloadInitialNavigationInBackground = false
            ensureBackgroundPreloadHostIfNeeded(reason: "initial-navigation")
        }
        if recordTypedNavigation {
            historyStore.recordTypedNavigation(url: originalURL)
        }
        browserLoadRequest(effectiveRequest, in: webView)
    }

    private func remoteProxyPreparedRequest(from request: URLRequest, logScope: String) -> URLRequest {
        guard remoteProxyEndpoint != nil else { return request }
        guard let url = request.url else { return request }
        guard let rewrittenURL = Self.remoteProxyLoopbackAliasURL(for: url) else { return request }

        var rewrittenRequest = request
        rewrittenRequest.url = rewrittenURL
#if DEBUG
        cmuxDebugLog(
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
        guard let displayHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = displayHost
        return components?.url ?? url
    }

    private static func remoteProxyLoopbackAliasURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return nil }
        guard RemoteLoopbackProxyAlias.isLoopbackHost(host) else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = RemoteLoopbackProxyAlias.browserAliasHost(
            forLoopbackHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        )
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

        let searchConfiguration = BrowserSearchSettingsStore().currentConfiguration
        guard let searchURL = searchConfiguration.searchURL(query: trimmed) else { return }
        navigate(to: searchURL)
    }

    func resolveNavigableURL(from input: String) -> URL? {
        resolveBrowserNavigableURL(input)
    }

    private func shouldBlockInsecureHTTPNavigation(to url: URL) -> Bool {
        if consumeOneTimeInsecureHTTPBypassIfNeeded(for: url) {
            return false
        }
        return browserShouldBlockInsecureHTTPURL(url)
    }

    @discardableResult
    private func consumeOneTimeInsecureHTTPBypassIfNeeded(for url: URL) -> Bool {
        browserShouldConsumeOneTimeInsecureHTTPBypass(url, bypassHostOnce: &insecureHTTPBypassHostOnce)
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
            openLinkInNewTab(request: request)
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

        if shouldDeferPromptUntilInteractiveHost(for: webView) {
            presentBrowserAlert(alert, in: webView, completion: handleResponse, cancel: {})
            return
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
                openLinkInNewTab(request: request, bypassInsecureHTTPHostOnce: host)
            }
        default:
            return
        }
    }

    deinit {
        hiddenWebViewDiscardManager.stop()
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

extension BrowserPanel: BrowserHiddenWebViewDiscardManagerDelegate {
    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
        BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
            isClosing: isClosingWebViewLifecycle,
            isVisibleInUI: isWebViewVisibleInUI,
            shouldRenderWebView: shouldRenderWebView,
            hasPendingRemoteNavigation: pendingRemoteNavigation != nil,
            hasCurrentURL: (currentURL ?? Self.remoteProxyDisplayURL(for: webView.url)) != nil,
            isLoading: isLoading,
            webViewIsLoading: webView.isLoading,
            hasActiveMainFrameProvisionalNavigation: isMainFrameProvisionalNavigationActive,
            isDownloading: isDownloading,
            activeDownloadCount: activeDownloadCount,
            preferredDeveloperToolsVisible: preferredDeveloperToolsVisible,
            isDeveloperToolsVisible: isDeveloperToolsVisible(),
            isElementFullscreenActive: isElementFullscreenActive,
            isReactGrabActive: isReactGrabActive,
            isVisualAutomationCaptureActive: activeVisualAutomationCaptureCount > 0,
            hasPopups: !popupControllers.isEmpty,
            isCapturingMedia: webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none,
            isPlayingMedia: isPlayingMedia
        )
    }

    var hiddenWebViewDiscardHiddenAt: Date? {
        webViewLastHiddenAt
    }

    var hiddenWebViewDiscardWebViewInstanceID: UUID {
        webViewInstanceID
    }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardHiddenWebViewForMemory(reason: reason)
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        reevaluateHiddenWebViewDiscardScheduling(reason: reason)
    }
}

extension BrowserPanel {
    private var needsWorkspaceContextReset: Bool {
        shouldRenderWebView ||
        currentURL != nil ||
        !pageTitle.isEmpty ||
        faviconPNGData != nil ||
        searchState != nil ||
        isBrowserFocusModeActive ||
        isBrowserFocusModeExitArmed ||
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
        hasRecoverableWebContentTermination ||
        pendingWebContentRecoveryURL != nil ||
        webView.superview != nil
    }

    func resetForWorkspaceContextChange(reason: String) {
        guard needsWorkspaceContextReset else {
            resetWebViewLifecycleMetadata()
#if DEBUG
            cmuxDebugLog(
                "browser.contextReset.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0)"
            )
#endif
            return
        }

#if DEBUG
        cmuxDebugLog(
            "browser.contextReset.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0) " +
            "url=\(preferredURLStringForOmnibar() ?? "nil")"
        )
#endif

        _ = hideDeveloperTools()
        clearBrowserFocusMode(reason: "contextReset")
        cancelDeveloperToolsRestoreRetry()
        setPreferredDeveloperToolsVisible(false)
        preferredDeveloperToolsPresentation = .unknown
        forceDeveloperToolsRefreshOnNextAttach = false
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsRestoreRetryAttempt = 0
        preferredAttachedDeveloperToolsWidth = nil
        preferredAttachedDeveloperToolsWidthFraction = nil
        clearWebContentTerminationRecovery()

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
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        preferredFocusIntent = .addressBar
        suppressOmnibarAutofocusUntil = nil
        suppressWebViewFocusUntil = nil
        endSuppressWebViewFocusForAddressBar()
        invalidateAddressBarPageFocusRestoreAttempts()
        invalidateSearchFocusRequests(reason: "contextReset")
        searchState = nil

        pageTitle = ""
        currentURL = nil
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
        faviconPNGData = nil
        lastFaviconURLString = nil
        resetWebViewLifecycleMetadata()
        activePortalHostLease = nil
        pendingDistinctPortalHostReplacementPaneId = nil
        lockedPortalHost = nil

        let oldWebView = webView
        webViewObservers.removeAll()
        webViewCancellables.removeAll()
        cancelPendingInteractiveBrowserPrompts(reason: "contextReset")
        closeBackgroundPreloadHost(reason: "contextReset")
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
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
        refreshWebViewLifecycleState()
        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()
        refreshNavigationAvailability()

#if DEBUG
        cmuxDebugLog(
            "browser.contextReset.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) instance=\(webViewInstanceID.uuidString.prefix(6))"
        )
#endif
    }
}

private func browserBareHostCandidate(_ lowercasedInput: String) -> String {
    let end = lowercasedInput.firstIndex { character in
        character == ":" || character == "/" || character == "?" || character == "#"
    } ?? lowercasedInput.endIndex
    return String(lowercasedInput[..<end])
}

func resolveBrowserNavigableURL(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.contains(" ") else { return nil }

    // Check localhost/loopback before generic URL parsing because
    // URL(string: "localhost:3777") treats "localhost" as a scheme.
    let lower = trimmed.lowercased()
    let bareHost = browserBareHostCandidate(lower)
    if lower.hasPrefix("localhost") ||
        lower.hasPrefix("127.0.0.1") ||
        lower.hasPrefix("[::1]") ||
        (bareHost != ".localhost" && bareHost.hasSuffix(".localhost")) {
        return URL(string: "http://\(trimmed)")
    }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            return url
        }
        if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
            return url
        }
        // URL(string: "example.com:8443") parses "example.com" as the scheme.
        // No real scheme contains a dot, so a dotted "scheme" followed by a
        // numeric port is a bare host:port that must navigate, not search.
        if browserDottedHostWithPortCandidate(trimmed, schemeCandidate: scheme) {
            return URL(string: "https://\(trimmed)")
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

private func browserDottedHostWithPortCandidate(_ input: String, schemeCandidate: String) -> Bool {
    guard schemeCandidate.contains(".") else { return false }
    guard input.count > schemeCandidate.count else { return false }
    let afterScheme = input.dropFirst(schemeCandidate.count)
    guard afterScheme.first == ":" else { return false }
    let portAndRest = afterScheme.dropFirst()
    let port = portAndRest.prefix(while: { $0.isNumber })
    guard !port.isEmpty, UInt16(port) != nil else { return false }
    let rest = portAndRest.dropFirst(port.count)
    return rest.isEmpty || rest.first == "/" || rest.first == "?" || rest.first == "#"
}

extension BrowserPanel {
    private func cancelInFlightNavigationBeforeHistoryTraversal() {
        guard webView.isLoading || isMainFrameProvisionalNavigationActive else { return }
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        let applied = applyMuteState(muted, to: webView, reason: "setMuted")
        if applied, isMuted != muted {
            isMuted = muted
        }
        return applied
    }

    @discardableResult
    func toggleMute() -> Bool {
        setMuted(!isMuted)
    }

    /// Go back in history
    func goBack() {
        guard canGoBack else { return }
        reactivateDiscardedWebViewWithoutNavigation(reason: "goBack")
        cancelInFlightNavigationBeforeHistoryTraversal()
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if (isLiveSessionHistoryAlignedWithRestoredCurrent || !nativeCanGoBack),
               let targetURL = restoredBackHistoryStack.popLast() {
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

            if nativeCanGoBack {
                webView.goBack()
                return
            }

            refreshNavigationAvailability()
            return
        }

        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        reactivateDiscardedWebViewWithoutNavigation(reason: "goForward")
        cancelInFlightNavigationBeforeHistoryTraversal()
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if nativeCanGoForward {
                webView.goForward()
                return
            }

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
        openLinkInNewTab(
            request: URLRequest(url: url),
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
    }

    /// Opens a request in a sibling browser tab without dropping request metadata.
    func openLinkInNewTab(request: URLRequest, bypassInsecureHTTPHostOnce: String? = nil) {
        guard let seed = browserNewTabNavigationSeed(
            from: request,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        ) else {
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) url=\(browserNavigationDebugURL(seed.url)) " +
            "bypass=\(seed.bypassInsecureHTTPHostOnce ?? "nil")"
        )
#endif
        guard BrowserAvailabilitySettings.isEnabled() else {
            _ = NSWorkspace.shared.open(seed.url)
#if DEBUG
            cmuxDebugLog("browser.newTab.open.external panel=\(id.uuidString.prefix(5)) reason=browser_disabled")
#endif
            return
        }
        guard let app = AppDelegate.shared else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=missingAppDelegate")
#endif
            return
        }
        guard let workspace = app.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=workspaceMissing")
#endif
            return
        }
        guard let paneId = workspace.paneId(forPanelId: id) else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=paneMissing")
#endif
            return
        }
        guard let _ = workspace.newBrowserSurface(
            inPane: paneId,
            url: seed.url,
            initialRequest: seed.initialRequest,
            focus: true,
            preferredProfileID: profileID,
            bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce
        ) else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=newPanelFailed")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.done panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5))"
        )
#endif
    }

    var currentURLForTabDuplication: URL? {
        resolvedCurrentSessionHistoryURL()
            ?? Self.remoteProxyDisplayURL(for: webView.url)
            ?? currentURL
    }

    var bypassesRemoteWorkspaceProxyForTabDuplication: Bool {
        bypassesRemoteWorkspaceProxy
    }

    /// Reload the current page
    func reload() {
        if recoverTerminatedWebContent(reason: "reload") {
            return
        }
        if restoreDiscardedWebViewIfNeeded(reason: "reload") {
            return
        }
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        if Self.serializableSessionHistoryURLString(Self.remoteProxyDisplayURL(for: webView.url)) == nil {
            let fallbackURL = resolvedCurrentSessionHistoryURL()
                ?? Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)

            if let fallbackURL,
               Self.serializableSessionHistoryURLString(fallbackURL) != nil {
                navigateWithoutInsecureHTTPPrompt(
                    to: fallbackURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: usesRestoredSessionHistory
                )
                return
            }
        }
        webView.reload()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
    }

    private static func windowContainsInspectorViews(_ root: NSView) -> Bool {
        if cmuxIsWebInspectorObject(root) {
            return true
        }
        for subview in root.subviews where windowContainsInspectorViews(subview) {
            return true
        }
        return false
    }

    static func isDetachedInspectorWindow(_ window: NSWindow) -> Bool {
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

    private func setPreferredDeveloperToolsVisible(_ next: Bool) {
        guard preferredDeveloperToolsVisible != next else { return }
        preferredDeveloperToolsVisible = next
    }

    private func reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden() {
        guard !preferredDeveloperToolsVisible, !isDeveloperToolsVisible() else { return }
        reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
    }

    private func syncDeveloperToolsPresentationPreferenceFromUI() {
        if hasAttachedDeveloperToolsLayout() {
            setPreferredDeveloperToolsPresentation(.attached)
            developerToolsDetachedOpenGraceDeadline = nil
        } else if !detachedDeveloperToolsWindows().isEmpty {
            setPreferredDeveloperToolsPresentation(.detached)
        }
    }

    private func installDetachedDeveloperToolsWindowCloseObserver() {
        guard detachedDeveloperToolsWindowCloseObserver == nil else { return }
        detachedDeveloperToolsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow else { return }
            guard Thread.isMainThread else { return }
            let handledDetachedInspector = MainActor.assumeIsolated {
                guard Self.isDetachedInspectorWindow(window) else { return false }
                return self.closeDeveloperToolsFromDetachedInspectorWindowWillClose(window)
            }
            guard handledDetachedInspector else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.preferredDeveloperToolsPresentation == .detached else { return }
                guard self.preferredDeveloperToolsVisible else { return }
                guard !self.isDeveloperToolsVisible() else { return }
                self.developerToolsDetachedOpenGraceDeadline = nil
                self.setPreferredDeveloperToolsVisible(false)
                self.reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
                self.cancelDeveloperToolsRestoreRetry()
#if DEBUG
                cmuxDebugLog(
                    "browser.devtools detachedClose.manual panel=\(self.id.uuidString.prefix(5)) " +
                    "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
                )
#endif
            }
        }
    }

    @discardableResult
    private func closeDeveloperToolsFromDetachedInspectorWindowWillClose(_ window: NSWindow) -> Bool {
        closeDeveloperToolsFromDetachedInspectorWindow(window, source: "willClose")
    }

    @discardableResult
    func closeDeveloperToolsFromDetachedInspectorWindowUserAction(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        closeDeveloperToolsFromDetachedInspectorWindow(window, source: source)
    }

    @discardableResult
    private func closeDeveloperToolsFromDetachedInspectorWindow(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        guard detachedDeveloperToolsWindowBelongsToPanel(window) else { return false }
        let closed = closeDeveloperToolsForTeardown()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.\(source) panel=\(id.uuidString.prefix(5)) " +
            "closed=\(closed ? 1 : 0) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return closed
    }

    private func detachedDeveloperToolsWindowBelongsToPanel(_ window: NSWindow) -> Bool {
        guard let frontendWebView = webView.cmuxInspectorFrontendWebView(),
              let contentView = window.contentView else {
            return false
        }
        return frontendWebView === contentView || frontendWebView.isDescendant(of: contentView)
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
            cmuxDebugLog(
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
        if preferredDeveloperToolsPresentation != .unknown {
            guard preferredDeveloperToolsPresentation == .attached else { return }
            guard webView.superview != nil, webView.window != nil else { return }
            guard inspector.cmuxCallBool(selector: NSSelectorFromString("isAttached")) == false else { return }
        }
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
            setPreferredDeveloperToolsVisible(targetVisible)
            if !targetVisible {
                developerToolsDetachedOpenGraceDeadline = nil
                forceDeveloperToolsRefreshOnNextAttach = false
                cancelDeveloperToolsRestoreRetry()
            }
#if DEBUG
            cmuxDebugLog(
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
        setPreferredDeveloperToolsVisible(targetVisible)
        developerToolsTransitionTargetVisible = targetVisible
        if targetVisible {
            reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
        }

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
            reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
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
        cmuxDebugLog(
            "browser.devtools toggle.begin panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        let targetVisible = !effectiveDeveloperToolsVisibilityIntent()
        let handled = enqueueDeveloperToolsVisibilityTransition(to: targetVisible, source: "toggle")
#if DEBUG
        cmuxDebugLog(
            "browser.devtools toggle.end panel=\(id.uuidString.prefix(5)) targetVisible=\(targetVisible ? 1 : 0) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            cmuxDebugLog(
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

    @discardableResult
    func closeDeveloperToolsForTeardown() -> Bool {
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        cancelDeveloperToolsRestoreRetry()

        let closed = WebViewInspectorTeardown.closeInspector(for: webView)
        setPreferredDeveloperToolsVisible(false)
        return closed
    }

    /// Called before WKWebView detaches so manual inspector closes are respected.
    func syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: Bool = false) {
        guard let inspector = webView.cmuxInspectorObject() else { return }
        guard let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) else { return }
        if isDeveloperToolsTransitionInFlight {
            let targetVisible = pendingDeveloperToolsTransitionTargetVisible ?? developerToolsTransitionTargetVisible ?? visible
            setPreferredDeveloperToolsVisible(targetVisible)
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
            setPreferredDeveloperToolsVisible(true)
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
            return
        }
        if preserveVisibleIntent && preferredDeveloperToolsVisible {
            return
        }
        setPreferredDeveloperToolsVisible(false)
        developerToolsLastKnownVisibleAt = nil
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        cancelDeveloperToolsRestoreRetry()
    }

    func noteDeveloperToolsHostAttached() {
        cancelPendingDeveloperToolsVisibilityLossCheck()
        // `developerToolsLastAttachedHostAt` anchors the manual-close detection
        // grace (see `consumeAttachedDeveloperToolsManualCloseIfNeeded`). Refresh it
        // only when this attach reflects genuine inspector churn: the inspector is
        // currently visible, a forced refresh is pending, or a restore retry is in
        // flight. While DevTools intent is set the browser stays in local-inline
        // hosting, so `BrowserPanelView` re-runs this on every `updateNSView`. A
        // plain re-render (e.g. navigating to another page) is not a reattach;
        // resetting the grace there would defer a user's manual inspector close
        // indefinitely and let `restoreDeveloperToolsAfterAttachIfNeeded` reopen it.
        if developerToolsLastAttachedHostAt == nil || hasActiveDeveloperToolsReattachReason {
            developerToolsLastAttachedHostAt = Date()
        }
        if isDeveloperToolsVisible() {
            developerToolsLastKnownVisibleAt = Date()
        }
    }

    /// Whether a host attach should count as genuine inspector churn that resets
    /// the manual-close grace window, rather than a steady-state re-render while
    /// the inspector is already closed.
    private var hasActiveDeveloperToolsReattachReason: Bool {
        isDeveloperToolsVisible()
            || forceDeveloperToolsRefreshOnNextAttach
            || developerToolsRestoreRetryWorkItem != nil
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

        setPreferredDeveloperToolsVisible(false)
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        cancelDeveloperToolsRestoreRetry()
#if DEBUG
        cmuxDebugLog(
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
                cmuxDebugLog("browser.devtools refresh.consumeVisible panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
            }
            #endif
            cancelDeveloperToolsRestoreRetry()
            return
        }

        let detachedOpenStillSettling = developerToolsDetachedOpenGraceDeadline.map { $0 > Date() } ?? false
        if preferredDeveloperToolsPresentation == .detached && !detachedOpenStillSettling {
            setPreferredDeveloperToolsVisible(false)
            developerToolsDetachedOpenGraceDeadline = nil
            cancelDeveloperToolsRestoreRetry()
#if DEBUG
            cmuxDebugLog(
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
            cmuxDebugLog("browser.devtools refresh.forceShowWhenHidden panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
        }
        #endif
        // WebKit inspector show can trigger transient first-responder churn while
        // panel attachment is still stabilizing. Keep this auto-restore path from
        // mutating first responder so AppKit doesn't walk tearing-down responder chains.
        AppDelegate.shared?.browserFirstResponderBypass.withBypass {
            _ = revealDeveloperTools(inspector)
        }
        setPreferredDeveloperToolsVisible(true)
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
        cmuxDebugLog("browser.devtools refresh.request panel=\(id.uuidString.prefix(5)) reason=\(reason) \(debugDeveloperToolsStateSummary())")
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
        captureAutomationVisibleViewportSnapshot { result in
            switch result {
            case .success(let image):
                completion(image)
            case .failure(let error):
                NSLog("BrowserPanel snapshot error: %@", error.localizedDescription)
                completion(nil)
            }
        }
    }

    func captureAutomationVisibleViewportSnapshot() async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            captureAutomationVisibleViewportSnapshot { result in
                continuation.resume(with: result)
            }
        }
    }

    func captureAutomationVisibleViewportSnapshot(
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        guard visualAutomationCaptureGate.begin() else {
            completion(.failure(BrowserScreenshotError.emptySnapshot))
            return
        }

        withVisualAutomationRenderLease(
            reason: "browser.screenshot",
            timeout: 15.0,
            operation: { webView, afterScreenUpdates, finish in
                BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                    from: webView,
                    afterScreenUpdates: afterScreenUpdates,
                    completion: finish
                )
            },
            completion: { [visualAutomationCaptureGate] result in
                visualAutomationCaptureGate.end()
                completion(result)
            }
        )
    }

    private func withVisualAutomationRenderLease<T>(
        reason: String,
        timeout: TimeInterval,
        operation: @escaping (
            _ webView: WKWebView,
            _ afterScreenUpdates: Bool,
            _ finish: @escaping (Result<T, Error>) -> Void
        ) -> Void,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        activeVisualAutomationCaptureCount += 1
        cancelHiddenWebViewDiscard()

        let expectedURLForRestoredWebView = restoredHistoryCurrentURL ?? currentURL
        let restoredDiscardedWebView = restoreDiscardedWebViewIfNeeded(reason: "\(reason).restore")
        let viewportSize = visualAutomationViewportSize()
        let captureWebView = webView
        var timeoutTimer: Timer?
        var didFinish = false
        let usesOffscreenRenderHost = shouldUseOffscreenRenderHostForVisualAutomation

        let finish: (Result<T, Error>) -> Void = { result in
            guard !didFinish else { return }
            didFinish = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil

            self.activeVisualAutomationCaptureCount = max(0, self.activeVisualAutomationCaptureCount - 1)
            self.refreshWebViewLifecycleState()
            if self.activeVisualAutomationCaptureCount == 0, !self.isWebViewVisibleInUI {
                self.scheduleHiddenWebViewDiscardIfNeeded(reason: "\(reason).finished")
            }

            completion(result)
        }

        if usesOffscreenRenderHost {
            ensureVisualAutomationRestoreHostIfNeeded(reason: "\(reason).restoreHost")
            BrowserScreenshotWebViewSnapshotter.withOffscreenRenderHost(
                captureWebView,
                viewportSize: viewportSize,
                expectedURL: restoredDiscardedWebView ? expectedURLForRestoredWebView : nil,
                timeout: timeout,
                operation: { operationFinish in
                    operation(captureWebView, false, operationFinish)
                },
                completion: finish
            )
            return
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            finish(.failure(BrowserScreenshotError.emptySnapshot))
        }

        BrowserScreenshotWebViewSnapshotter.prepareForVisualCapture(
            captureWebView,
            expectedURL: restoredDiscardedWebView ? expectedURLForRestoredWebView : nil
        ) { result in
            switch result {
            case .success:
                operation(captureWebView, false, finish)
            case .failure(let error):
                finish(.failure(error))
            }
        }
    }

    @discardableResult
    func ensureVisualAutomationRestoreHostIfNeeded(reason: String) -> Bool {
        guard shouldUseOffscreenRenderHostForVisualAutomation else { return false }
        guard webView.superview == nil else { return false }
        return ensureBackgroundPreloadHostIfNeeded(reason: reason)
    }

    private var shouldUseOffscreenRenderHostForVisualAutomation: Bool {
        guard isWebViewVisibleInUI else { return true }
        guard webView.window != nil else { return true }
        guard !webView.isHiddenOrHasHiddenAncestor else { return true }
        guard webView.bounds.width > 1, webView.bounds.height > 1 else { return true }
        return false
    }

    private func visualAutomationViewportSize() -> NSSize {
        let candidates = [
            webView.bounds.size,
            webView.frame.size,
            webView.window?.contentView?.bounds.size ?? .zero,
        ]
        for candidate in candidates where candidate.width > 1 && candidate.height > 1 {
            return NSSize(
                width: min(max(candidate.width, 1), 4096),
                height: min(max(candidate.height, 1), 4096)
            )
        }
        return NSSize(width: 1280, height: 720)
    }

    /// Execute JavaScript
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    // MARK: - Find in Page

    func startFind() {
        clearBrowserFocusMode(reason: "startFind")
        preferredFocusIntent = .findField
        let created = searchState == nil
        let recoveredNeedle = created ? lastSearchNeedle : ""
        if created { searchState = BrowserSearchState(needle: recoveredNeedle) }
        let shouldSelectAll = created && !recoveredNeedle.isEmpty
        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
        let generation = beginSearchFocusRequest(reason: "startFind")
        postBrowserSearchFocusNotification(reason: "immediate", generation: generation, selectAll: shouldSelectAll)
        // Re-post because portal overlay mount can race first responder focus.
        DispatchQueue.main.async { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async0", generation: generation, selectAll: shouldSelectAll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postBrowserSearchFocusNotification(reason: "async50ms", generation: generation, selectAll: shouldSelectAll)
        }
    }

    private func postBrowserSearchFocusNotification(reason: String, generation: UInt64, selectAll: Bool) {
        guard canApplySearchFocusRequest(generation) else {
#if DEBUG
            cmuxDebugLog(
                "browser.find.focusNotification.skip panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) generation=\(generation)"
            )
#endif
            return
        }
#if DEBUG
        let window = webView.window
        cmuxDebugLog(
            "browser.find.focusNotification panel=\(id.uuidString.prefix(5)) " +
            "generation=\(generation) " +
            "reason=\(reason) selectAll=\(selectAll ? 1 : 0) window=\(window?.windowNumber ?? -1) " +
            "firstResponder=\(String(describing: window?.firstResponder))"
        )
#endif
        NotificationCenter.default.post(name: .browserSearchFocus, object: id, userInfo: [FindFocusNotificationKey.selectAll: selectAll])
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
        let shouldRestoreWebViewFocus = searchState != nil && preferredFocusIntent == .findField
        invalidateSearchFocusRequests(reason: "hideFind")
        searchState = nil
        if shouldRestoreWebViewFocus { focus() }
    }

    var canEnterBrowserFocusMode: Bool {
        shouldRenderWebView &&
            browserInteractiveModalHostWindow(for: webView) != nil &&
            !webView.isHiddenOrHasHiddenAncestor &&
            searchState == nil
    }

    var canToggleBrowserFocusMode: Bool {
        isBrowserFocusModeActive || canEnterBrowserFocusMode
    }

    @discardableResult
    func toggleBrowserFocusMode(reason: String, focusWebView: Bool = true) -> Bool {
        setBrowserFocusModeActive(
            !isBrowserFocusModeActive,
            reason: reason,
            focusWebView: focusWebView
        )
    }

    @discardableResult
    func setBrowserFocusModeActive(
        _ active: Bool,
        reason: String,
        focusWebView: Bool = true
    ) -> Bool {
        if !active {
            clearBrowserFocusMode(reason: reason)
            return true
        }

        guard canEnterBrowserFocusMode else {
#if DEBUG
            cmuxDebugLog(
                "browser.focusMode.activate.reject panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0) " +
                "window=\(webView.window == nil ? 0 : 1) hidden=\(webView.isHiddenOrHasHiddenAncestor ? 1 : 0) " +
                "find=\(searchState == nil ? 0 : 1)"
            )
#endif
            return false
        }

        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        isBrowserFocusModeActive = true
        clearBrowserFocusModeEscapeArms(reason: "\(reason).activate")
        preferredFocusIntent = .webView
        invalidateSearchFocusRequests(reason: "browserFocusModeActivate")

        let didFocus = focusWebView ? requestExplicitWebViewFocus() : true
        guard didFocus else {
            clearBrowserFocusMode(reason: "\(reason).focusFailed")
            return false
        }

#if DEBUG
        cmuxDebugLog("browser.focusMode.activate panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        NotificationCenter.default.post(name: .browserFocusModeStateDidChange, object: id)
        return true
    }

    func clearBrowserFocusMode(reason: String) {
        let shouldNotify = isBrowserFocusModeActive || isBrowserFocusModeExitArmed
        guard isBrowserFocusModeActive ||
            isBrowserFocusModeExitArmed ||
            browserFocusModeExitArmedAt != nil ||
            lastBrowserFocusModePlainEscapeEventFingerprint != nil
        else { return }
        browserFocusModeExitArmedAt = nil
        lastBrowserFocusModePlainEscapeEventFingerprint = nil
        isBrowserFocusModeExitArmed = false
        isBrowserFocusModeActive = false
#if DEBUG
        cmuxDebugLog("browser.focusMode.clear panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        if shouldNotify {
            NotificationCenter.default.post(name: .browserFocusModeStateDidChange, object: id)
        }
    }

    func clearBrowserFocusModeEscapeArms(reason: String) {
        clearBrowserFocusModeExitArm(reason: reason)
        lastBrowserFocusModePlainEscapeEventFingerprint = nil
    }

    func clearBrowserFocusModeExitArm(reason: String) {
        guard isBrowserFocusModeExitArmed || browserFocusModeExitArmedAt != nil else { return }
        browserFocusModeExitArmedAt = nil
        isBrowserFocusModeExitArmed = false
#if DEBUG
        cmuxDebugLog("browser.focusMode.escape.disarm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
    }

    private func browserFocusModeEscapeArmIsFresh(for event: NSEvent) -> Bool {
        guard let startedAt = browserFocusModeExitArmedAt else { return false }
        guard startedAt > 0, event.timestamp > 0 else { return true }
        return max(0, event.timestamp - startedAt) <= Self.browserFocusModeEscapeSequenceInterval
    }

    func handleBrowserFocusModeKeyEvent(_ event: NSEvent, reason: String) -> BrowserFocusModeKeyDecision {
        guard canEnterBrowserFocusMode else {
            clearBrowserFocusMode(reason: "\(reason).ineligible")
            return .inactive
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainEscape = flags.isEmpty && event.keyCode == 53
        guard isPlainEscape else {
            lastBrowserFocusModePlainEscapeEventFingerprint = nil
            clearBrowserFocusModeEscapeArms(reason: "\(reason).nonEscape")
            return isBrowserFocusModeActive ? .forwardToWebView : .inactive
        }

        guard isBrowserFocusModeActive else {
            lastBrowserFocusModePlainEscapeEventFingerprint = nil
            clearBrowserFocusModeEscapeArms(reason: "\(reason).inactiveEscape")
            return .inactive
        }

        guard !event.isARepeat else {
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.repeat panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .consume
        }

        let eventFingerprint = BrowserFocusModePlainEscapeEventFingerprint(event)
        if lastBrowserFocusModePlainEscapeEventFingerprint == eventFingerprint {
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.duplicate panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .consume
        }
        lastBrowserFocusModePlainEscapeEventFingerprint = eventFingerprint

        if isBrowserFocusModeExitArmed {
            if browserFocusModeEscapeArmIsFresh(for: event) {
                clearBrowserFocusMode(reason: "\(reason).escapeExit")
                return .consume
            }

            browserFocusModeExitArmedAt = event.timestamp
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.rearm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .forwardToWebView
        }

        isBrowserFocusModeExitArmed = true
        browserFocusModeExitArmedAt = event.timestamp
#if DEBUG
        cmuxDebugLog("browser.focusMode.escape.arm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        return .forwardToWebView
    }

    private func restoreFindStateAfterNavigation(replaySearch: Bool) {
        guard let state = searchState else { return }
        state.total = nil
        state.selected = nil
        if replaySearch, !state.needle.isEmpty {
            executeFindSearch(state.needle)
        }
        postBrowserSearchFocusNotification(reason: "restoreAfterNavigation", generation: searchFocusRequestGeneration, selectAll: false)
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
        for controller in popupControllers {
            controller.setBrowserThemeMode(mode)
        }
    }

    func refreshAppearanceDrivenColors() {
        applyConfiguredWebViewBackground()
    }

    func suppressOmnibarAutofocus(for seconds: TimeInterval) {
        suppressOmnibarAutofocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.omnibarAutofocus.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func suppressWebViewFocus(for seconds: TimeInterval) {
        suppressWebViewFocusUntil = Date().addingTimeInterval(seconds)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.webView.suppress panel=\(id.uuidString.prefix(5)) " +
            "seconds=\(String(format: "%.2f", seconds))"
        )
#endif
    }

    func clearWebViewFocusSuppression() {
        suppressWebViewFocusUntil = nil
#if DEBUG
        cmuxDebugLog("browser.focus.webView.suppress.clear panel=\(id.uuidString.prefix(5))")
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
            cmuxDebugLog("browser.focus.addressBarSuppress.begin panel=\(id.uuidString.prefix(5))")
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
            cmuxDebugLog("browser.focus.addressBarSuppress.end panel=\(id.uuidString.prefix(5))")
#endif
        }
        suppressWebViewFocusForAddressBar = false
    }

    @discardableResult
    func requestAddressBarFocus(
        selectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    ) -> UUID {
        clearBrowserFocusMode(reason: "requestAddressBarFocus")
        setOmnibarVisible(true)
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "requestAddressBarFocus")
        beginSuppressWebViewFocusForAddressBar()
        if let pendingAddressBarFocusRequestId {
            if selectionIntent == .selectAll,
               pendingAddressBarFocusSelectionIntent != .selectAll {
                let requestId = UUID()
                pendingAddressBarFocusSelectionIntent = .selectAll
                self.pendingAddressBarFocusRequestId = requestId
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
                    "request=\(requestId.uuidString.prefix(8)) result=upgrade_to_select_all"
                )
#endif
                return requestId
            }
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
                "request=\(pendingAddressBarFocusRequestId.uuidString.prefix(8)) result=reuse_pending " +
                "selection=\(String(describing: pendingAddressBarFocusSelectionIntent))"
            )
#endif
            return pendingAddressBarFocusRequestId
        }
        let requestId = UUID()
        pendingAddressBarFocusSelectionIntent = selectionIntent
        pendingAddressBarFocusRequestId = requestId
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.request panel=\(id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) result=new " +
            "selection=\(String(describing: selectionIntent))"
        )
#endif
        return requestId
    }

    @discardableResult
    func setOmnibarVisible(_ visible: Bool) -> Bool {
        guard isOmnibarVisible != visible else { return false }
        isOmnibarVisible = visible
        if !visible {
            pendingAddressBarFocusRequestId = nil
            pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
            if preferredFocusIntent == .addressBar {
                preferredFocusIntent = .webView
            }
            endSuppressWebViewFocusForAddressBar()
            invalidateAddressBarPageFocusRestoreAttempts()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
        }
        return true
    }

    @discardableResult
    func toggleOmnibarVisibility() -> Bool {
        setOmnibarVisible(!isOmnibarVisible)
        return isOmnibarVisible
    }

    func noteWebViewFocused() {
        guard searchState == nil else { return }
        guard preferredFocusIntent != .webView else { return }
        preferredFocusIntent = .webView
        invalidateSearchFocusRequests(reason: "webViewFocused")
    }

    func noteAddressBarFocused() {
        clearBrowserFocusMode(reason: "addressBarFocused")
        guard preferredFocusIntent != .addressBar else { return }
        preferredFocusIntent = .addressBar
        invalidateSearchFocusRequests(reason: "addressBarFocused")
    }

    func noteFindFieldFocused() {
        clearBrowserFocusMode(reason: "findFieldFocused")
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
            clearBrowserFocusMode(reason: "prepareAddressBar")
            preferredFocusIntent = .addressBar
            invalidateSearchFocusRequests(reason: "prepareAddressBar")
            beginSuppressWebViewFocusForAddressBar()
        case .findField:
            clearBrowserFocusMode(reason: "prepareFindField")
            preferredFocusIntent = .findField
        }
#if DEBUG
        cmuxDebugLog(
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
            let requestId = requestAddressBarFocus(selectionIntent: .preserveFieldEditorSelection)
            NotificationCenter.default.post(name: .browserFocusAddressBar, object: id)
#if DEBUG
            cmuxDebugLog(
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
        if AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id,
           browserOmnibarPanelId(for: responder) == id {
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
                cmuxDebugLog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=browserFind")
            }
#endif
            return yielded
        case .addressBar:
            guard AppDelegate.shared?.focusedBrowserAddressBarPanelId() == id else { return false }
            guard browserOmnibarPanelId(for: window.firstResponder) == id else {
                clearAddressBarFocusTrackingForYield()
                return false
            }
            browserPrepareOmnibarForProgrammaticBlur(panelId: id, responder: window.firstResponder)
            clearAddressBarFocusTrackingForYield()
#if DEBUG
            cmuxDebugLog("focus.handoff.yield panel=\(id.uuidString.prefix(5)) target=addressBar")
#endif
            return true
        case .webView:
            guard Self.responderChainContains(window.firstResponder, target: webView) else { return false }
            return window.makeFirstResponder(nil)
        }
    }

    private func clearAddressBarFocusTrackingForYield() {
        endSuppressWebViewFocusForAddressBar()
        AppDelegate.shared?.clearBrowserAddressBarFocus(panelId: id, reason: "yield")
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
    }

    @discardableResult
    private func beginSearchFocusRequest(reason: String) -> UInt64 {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "browser.find.focusLease.begin panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
        return searchFocusRequestGeneration
    }

    private func invalidateSearchFocusRequests(reason: String) {
        searchFocusRequestGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "browser.find.focusLease.invalidate panel=\(id.uuidString.prefix(5)) " +
            "generation=\(searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
    }

    func acknowledgeAddressBarFocusRequest(_ requestId: UUID) {
        guard pendingAddressBarFocusRequestId == requestId else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.requestAck panel=\(id.uuidString.prefix(5)) " +
                "request=\(requestId.uuidString.prefix(8)) result=ignored " +
                "pending=\(pendingAddressBarFocusRequestId?.uuidString.prefix(8) ?? "nil")"
            )
#endif
            return
        }
        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
#if DEBUG
        cmuxDebugLog(
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
                cmuxDebugLog(
                    "browser.focus.addressBar.capture panel=\(self.id.uuidString.prefix(5)) " +
                    "result=error message=\(error.localizedDescription)"
                )
                return
            }
            let resultValue = (result as? String) ?? "unknown"
            cmuxDebugLog(
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
        cmuxDebugLog(
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
                cmuxDebugLog(
                    "browser.focus.addressBar.restore panel=\(self.id.uuidString.prefix(5)) " +
                    "attempt=\(attempt) status=\(status.rawValue) " +
                    "message=\(error.localizedDescription)"
                )
            } else {
                cmuxDebugLog(
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
            resolvedCanGoBack = nativeCanGoBack || !restoredBackHistoryStack.isEmpty
            resolvedCanGoForward = nativeCanGoForward || !restoredForwardHistoryStack.isEmpty
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
        guard !isTemporarySessionHistoryURL(url) else { return nil }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "about:blank" else { return nil }
        return value
    }

    private static func sanitizedSessionHistoryURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "about:blank" else { return nil }
        guard let url = URL(string: trimmed),
              !isTemporarySessionHistoryURL(url) else {
            return nil
        }
        return url
    }

    private static func sanitizedSessionHistoryURLs(_ values: [String]) -> [URL] {
        values.compactMap { sanitizedSessionHistoryURL($0) }
    }

    private static func isTemporarySessionHistoryURL(_ url: URL?) -> Bool {
        browserIsTemporaryHistoryURL(url)
    }

}

private extension BrowserPanel {
    func applyBrowserThemeModeIfNeeded() {
        BrowserThemeSettings.apply(browserThemeMode, to: webView)
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
            if let self, let window = browserInteractiveModalHostWindow(for: self.webView) {
                return window
            }
            return browserFallbackInteractiveModalHostWindow()
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
                if cmuxIsWebInspectorObject(subview) {
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
        cmuxIsWebInspectorObject(view)
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
        noteWebViewVisibility(
            false,
            reason: "portal.\(source)",
            recordIfUnchanged: true
        )
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

@MainActor
enum WebViewInspectorTeardown {
    @discardableResult
    static func closeAllInspectors(in window: NSWindow) -> Int {
        assert(Thread.isMainThread)

        return webViews(in: window).reduce(0) { count, webView in
            closeInspector(for: webView) ? count + 1 : count
        }
    }

    @discardableResult
    static func closeAllInspectors(in windows: [NSWindow]) -> Int {
        windows.reduce(0) { count, window in
            count + closeAllInspectors(in: window)
        }
    }

    @discardableResult
    static func closeInspector(for webView: WKWebView) -> Bool {
        assert(Thread.isMainThread)

        guard !isInspectorFrontendWebView(webView),
              let inspector = webView.cmuxInspectorObject() else {
            return false
        }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let isAttachedSelector = NSSelectorFromString("isAttached")
        let isVisible = inspector.cmuxCallBool(selector: isVisibleSelector)
        let isAttached = inspector.cmuxCallBool(selector: isAttachedSelector)
        let shouldClose = (isVisible == true)
            || (isAttached == true)
            || (isVisible == nil && isAttached == nil)
        guard shouldClose else { return false }

        // cmux already opens Web Inspector through WebKit's `_inspector` object
        // because the deployable SDK surface does not expose a stable close API.
        // Keep teardown on the same auditable SPI path so WebKit unregisters the
        // inspector window observers before the parent AppKit close cascade runs.
        let closeSelector = NSSelectorFromString("close")
        guard inspector.responds(to: closeSelector) else { return false }
        inspector.cmuxCallVoid(selector: closeSelector)
        return true
    }

    private static func webViews(in window: NSWindow) -> [WKWebView] {
        var seen = Set<ObjectIdentifier>()
        var result: [WKWebView] = []
        let roots = [window.contentView, window.contentView?.superview].compactMap { $0 }
        for root in roots {
            collectWebViews(in: root, seen: &seen, result: &result)
        }
        return result
    }

    private static func collectWebViews(
        in view: NSView,
        seen: inout Set<ObjectIdentifier>,
        result: inout [WKWebView]
    ) {
        if let webView = view as? WKWebView,
           !isInspectorFrontendWebView(webView) {
            let id = ObjectIdentifier(webView)
            if !seen.contains(id) {
                seen.insert(id)
                result.append(webView)
            }
        }

        for subview in view.subviews {
            collectWebViews(in: subview, seen: &seen, result: &result)
        }
    }

    private static func isInspectorFrontendWebView(_ webView: WKWebView) -> Bool {
        cmuxIsWebInspectorObject(webView)
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
    private struct DownloadState: Sendable {
        let tempURL: URL
        let suggestedFilename: String
        let sourceURL: URL
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
        let filenameResolver = BrowserDownloadFilenameResolver()
        if case .reject = filenameResolver.httpStatusDecision(for: response) {
            completionHandler(nil)
            return
        }
        let sourceURL = response.url ?? URL(fileURLWithPath: suggestedFilename)
        let safeFilename = filenameResolver.suggestedFilename(suggestedFilename: suggestedFilename, response: response, sourceURL: sourceURL, imageType: nil)
        let tempFilename = "\(UUID().uuidString)-\(safeFilename)"
        let destURL = Self.tempDir.appendingPathComponent(tempFilename, isDirectory: false)
        try? FileManager.default.removeItem(at: destURL)
        storeState(DownloadState(tempURL: destURL, suggestedFilename: safeFilename, sourceURL: sourceURL), for: download)
        notifyOnMain { [weak self] in
            self?.onDownloadStarted?(safeFilename)
        }
        #if DEBUG
        cmuxDebugLog("download.decideDestination file=\(safeFilename)")
        #endif
        completionHandler(destURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = removeState(for: download) else {
            #if DEBUG
            cmuxDebugLog("download.finished missing-state")
            #endif
            return
        }
        #if DEBUG
        cmuxDebugLog("download.finished file=\(info.suggestedFilename)")
        #endif
        let filenameResolver = BrowserDownloadFilenameResolver()
        Task { @MainActor in
            let imageType = await Task.detached(priority: .utility) {
                filenameResolver.imageType(forDownloadedFileAt: info.tempURL)
            }.value
            self.onDownloadReadyToSave?()
            let suggestedFilename = filenameResolver.suggestedFilename(suggestedFilename: info.suggestedFilename, response: nil, sourceURL: info.sourceURL, imageType: imageType)
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = suggestedFilename
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            savePanel.begin { result in
                guard result == .OK, let destURL = savePanel.url else {
                    try? FileManager.default.removeItem(at: info.tempURL)
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        _ = try FileManager.default.replaceItemAt(destURL, withItemAt: info.tempURL)
                    } else {
                        try FileManager.default.moveItem(at: info.tempURL, to: destURL)
                    }
                } catch {
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
        cmuxDebugLog("download.failed error=\(error.localizedDescription)")
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
    popupFeaturesWereSpecified: Bool = false,
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
    return navigationType == .other && popupFeaturesWereSpecified && !isUserNewTab
}

func browserNavigationShouldFallbackNilTargetToNewTab(
    navigationType: WKNavigationType
) -> Bool {
    // Scripted popups rely on WKUIDelegate.createWebViewWith returning a live
    // web view so window.opener/postMessage remain intact across OAuth flows.
    navigationType != .other
}

func browserNavigationHasSimpleUserActivation(
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type
) -> Bool {
    switch currentEventType {
    case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp:
        return true
    default:
        return false
    }
}

func browserNavigationPopupFeaturesWereSpecified(
    x: NSNumber?,
    y: NSNumber?,
    width: NSNumber?,
    height: NSNumber?,
    menuBarVisibility: NSNumber?,
    statusBarVisibility: NSNumber?,
    toolbarsVisibility: NSNumber?,
    allowsResizing: NSNumber?
) -> Bool {
    x != nil ||
        y != nil ||
        width != nil ||
        height != nil ||
        menuBarVisibility != nil ||
        statusBarVisibility != nil ||
        toolbarsVisibility != nil ||
        allowsResizing != nil
}

func browserNavigationPopupFeaturesWereSpecified(windowFeatures: WKWindowFeatures) -> Bool {
    browserNavigationPopupFeaturesWereSpecified(
        x: windowFeatures.x,
        y: windowFeatures.y,
        width: windowFeatures.width,
        height: windowFeatures.height,
        menuBarVisibility: windowFeatures.menuBarVisibility,
        statusBarVisibility: windowFeatures.statusBarVisibility,
        toolbarsVisibility: windowFeatures.toolbarsVisibility,
        allowsResizing: windowFeatures.allowsResizing
    )
}
// Keep popup retargeting intentionally narrow. Explicit cross-host alias groups
// preserve known first-party search flows without guessing at the public suffix
// list for arbitrary hosted tenants, while same-host scripted popups stay on
// the popup path so opener-dependent browser flows keep working.
private let browserNavigationSimpleUserGesturePopupRetargetHostAliases: [Set<String>] = [
    [
        "bilibili.com",
        "search.bilibili.com",
        "www.bilibili.com",
    ],
]

private func browserNavigationDefaultPort(for scheme: String) -> Int? {
    switch scheme {
    case "http":
        return 80
    case "https":
        return 443
    default:
        return nil
    }
}

private func browserNavigationShouldRetargetSimpleUserGesturePopup(
    requestURL: URL?,
    openerURL: URL?
) -> Bool {
    guard let requestURL,
          let openerURL,
          let requestScheme = requestURL.scheme?.lowercased(), !requestScheme.isEmpty,
          let openerScheme = openerURL.scheme?.lowercased(), !openerScheme.isEmpty,
          requestScheme == openerScheme,
          (requestURL.port ?? browserNavigationDefaultPort(for: requestScheme))
            == (openerURL.port ?? browserNavigationDefaultPort(for: openerScheme)),
          let requestHost = BrowserInsecureHTTPSettings.normalizeHost(requestURL.host ?? ""),
          let openerHost = BrowserInsecureHTTPSettings.normalizeHost(openerURL.host ?? "") else {
        return false
    }
    for aliases in browserNavigationSimpleUserGesturePopupRetargetHostAliases {
        if requestHost != openerHost,
           aliases.contains(requestHost),
           aliases.contains(openerHost) {
            return true
        }
    }
    return false
}

private func browserNavigationDebugURL(_ url: URL?) -> String {
    guard let url,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return "nil"
    }
    components.query = nil
    components.fragment = nil
    return components.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "")"
}

func browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
    navigationType: WKNavigationType,
    requestMethod: String?,
    requestURL: URL?,
    openerURL: URL?,
    modifierFlags: NSEvent.ModifierFlags = [],
    buttonNumber: Int = 0,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber,
    popupFeaturesWereSpecified: Bool
) -> Bool {
    guard navigationType == .other else {
        return false
    }
    // Some sites use `window.open()` for plain same-site searches triggered by a
    // direct keyboard submit or left-click, without requesting popup chrome or
    // opener-style geometry. Route those to a normal tab while keeping
    // cross-site/OAuth-style popups on the popup path.
    guard browserNavigationHasSimpleUserActivation(currentEventType: currentEventType) else {
        return false
    }
    guard !browserNavigationShouldOpenInNewTab(
        navigationType: navigationType,
        modifierFlags: modifierFlags,
        buttonNumber: buttonNumber,
        hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
        currentEventType: currentEventType,
        currentEventButtonNumber: currentEventButtonNumber
    ) else {
        return false
    }
    guard (requestMethod ?? "GET").uppercased() == "GET" else {
        return false
    }
    guard !popupFeaturesWereSpecified else {
        return false
    }
    return browserNavigationShouldRetargetSimpleUserGesturePopup(
        requestURL: requestURL,
        openerURL: openerURL
    )
}

private class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    var didStartProvisionalNavigation: ((WKWebView) -> Void)?
    var didCommit: ((WKWebView) -> Void)?
    var didFinish: ((WKWebView) -> Void)?
    var didFailNavigation: ((WKWebView, String) -> Void)?
    var didCancelProvisionalNavigation: ((WKWebView) -> Void)?
    var didTerminateWebContentProcess: ((WKWebView) -> Void)?
    var openInNewTab: ((URL) -> Void)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var presentAlert: BrowserAlertPresenter = browserPresentAlert
    var shouldBlockInsecureHTTPNavigation: ((URL) -> Bool)?
    var handleBlockedInsecureHTTPNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    /// Direct reference to the download delegate — must be set synchronously in didBecome callbacks.
    var downloadDelegate: WKDownloadDelegate?
    /// The URL of the last navigation that was attempted. Used to preserve the omnibar URL
    /// when a provisional navigation fails (e.g. connection refused on localhost:3000).
    var lastAttemptedURL: URL?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastAttemptedURL = lastAttemptedURL ?? webView.url
        didStartProvisionalNavigation?(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        didCommit?(webView)
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
            didCancelProvisionalNavigation?(webView)
            return
        }

        // "Frame load interrupted" (WebKitErrorDomain code 102) fires when a
        // navigation response is converted into a download via .download policy.
        // This is expected and should not show an error page.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            didCancelProvisionalNavigation?(webView)
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
        cmuxDebugLog("browser.webcontent.terminated panel=\(String(describing: self))")
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
        let openRequestInNewTab: (URLRequest) -> Void = { [requestNavigation, openInNewTab] request in
            if let requestNavigation {
                requestNavigation(request, .newTab)
                return
            }
            if let url = request.url {
                openInNewTab?(url)
            }
        }
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
        let requestMethod = navigationAction.request.httpMethod ?? "nil"
        let requestURL = browserNavigationDebugURL(navigationAction.request.url)
        let targetMainFrame = navigationAction.targetFrame.map { $0.isMainFrame ? "1" : "0" } ?? "nil"
        cmuxDebugLog(
            "browser.nav.decidePolicy navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "targetMain=\(targetMainFrame) method=\(requestMethod) url=\(requestURL) " +
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
            cmuxDebugLog(
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
           browserShouldRouteExternalNavigation(url) {
            browserHandleExternalNavigation(
                url,
                source: "navDelegate",
                webView: webView,
                loadFallbackRequest: { [requestNavigation] request in
                    requestNavigation?(request, .currentTab)
                },
                presentAlert: presentAlert
            )
            decisionHandler(.cancel)
            return
        }

        // Cmd+click and middle-click on regular links should always open in a new tab.
        if shouldOpenInNewTab,
           let requestURL = navigationAction.request.url {
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=openInNewTab url=\(requestURL.absoluteString)"
            )
#endif
            openRequestInNewTab(navigationAction.request)
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
           let requestURL = navigationAction.request.url {
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=openInNewTabFromNilTarget url=\(requestURL.absoluteString)"
            )
#endif
            openRequestInNewTab(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

#if DEBUG
        let targetURL = navigationAction.request.url?.absoluteString ?? "nil"
        cmuxDebugLog("browser.nav.decidePolicy.action kind=allow url=\(targetURL)")
#endif
        if navigationAction.targetFrame?.isMainFrame != false {
            lastAttemptedURL = navigationAction.request.url
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
                cmuxDebugLog("download.policy=download reason=content-disposition mime=\(mime)")
                #endif
                decisionHandler(.download)
                return
            }
        }

        if !canShow {
            NSLog("BrowserPanel download: cannotShowMIME mime=%@ url=%@", mime, responseURL)
            #if DEBUG
            cmuxDebugLog("download.policy=download reason=cannotShowMIME mime=\(mime)")
            #endif
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationAction")
        #endif
        NSLog("BrowserPanel download didBecome from navigationAction")
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationResponse")
        #endif
        NSLog("BrowserPanel download didBecome from navigationResponse")
        download.delegate = downloadDelegate
    }
}

// MARK: - UI Delegate

private class BrowserUIDelegate: NSObject, WKUIDelegate {
    var openInNewTab: ((URL) -> Void)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var presentAlert: BrowserAlertPresenter = browserPresentAlert
    var openPopup: ((WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?)?
    var closeRequested: ((WKWebView) -> Void)?

    func webViewDidClose(_ webView: WKWebView) {
        closeRequested?(webView)
    }

    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
    }

    private func presentDialog(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        cancel: @escaping () -> Void
    ) {
        presentAlert(alert, webView, completion, cancel)
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
        let requestMethod = navigationAction.request.httpMethod ?? "nil"
        let requestURL = navigationAction.request.url?.absoluteString ?? "nil"
        let targetMainFrame = navigationAction.targetFrame.map { $0.isMainFrame ? "1" : "0" } ?? "nil"
        let windowFeaturesSummary = [
            "x=\(windowFeatures.x?.stringValue ?? "nil")",
            "y=\(windowFeatures.y?.stringValue ?? "nil")",
            "w=\(windowFeatures.width?.stringValue ?? "nil")",
            "h=\(windowFeatures.height?.stringValue ?? "nil")",
            "toolbars=\(windowFeatures.toolbarsVisibility?.stringValue ?? "nil")",
            "resizable=\(windowFeatures.allowsResizing?.stringValue ?? "nil")",
            "status=\(windowFeatures.statusBarVisibility?.stringValue ?? "nil")",
            "menu=\(windowFeatures.menuBarVisibility?.stringValue ?? "nil")"
        ].joined(separator: ",")
        cmuxDebugLog(
            "browser.nav.createWebView navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "targetMain=\(targetMainFrame) method=\(requestMethod) url=\(requestURL) " +
            "eventType=\(currentEventType) eventButton=\(currentEventButton) " +
            "windowFeatures={\(windowFeaturesSummary)}"
        )
#endif
        // External URL schemes → hand off to macOS, don't create a popup
        if let url = navigationAction.request.url,
           browserShouldRouteExternalNavigation(url) {
            browserHandleExternalNavigation(
                url,
                source: "uiDelegate",
                webView: webView,
                loadFallbackRequest: { [requestNavigation] request in
                    requestNavigation?(request, .currentTab)
                },
                presentAlert: presentAlert
            )
            return nil
        }

        let hasRecentMiddleClickIntent = CmuxWebView.hasRecentMiddleClickIntent(for: webView)
        let popupFeaturesWereSpecified = browserNavigationPopupFeaturesWereSpecified(windowFeatures: windowFeatures)
        let shouldOpenSimpleUserGesturePopupInCurrentTab = browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
            navigationType: navigationAction.navigationType,
            requestMethod: navigationAction.request.httpMethod,
            requestURL: navigationAction.request.url,
            openerURL: webView.url,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified
        )

        if shouldOpenSimpleUserGesturePopupInCurrentTab {
            if let url = navigationAction.request.url {
#if DEBUG
                cmuxDebugLog(
                    "browser.nav.createWebView.action kind=requestNavigationSimpleUserGesture intent=currentTab " +
                    "url=\(browserNavigationDebugURL(url))"
                )
#endif
                if let requestNavigation {
                    requestNavigation(navigationAction.request, .currentTab)
                } else {
                    browserLoadRequest(navigationAction.request, in: webView)
                }
            }
            return nil
        }

        // Only treat scripted `.other` requests as popups when WebKit surfaced
        // explicit window features; bare `_blank` falls through to tabs.
        let isScriptedPopup = browserNavigationShouldCreatePopup(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent
        )

        if isScriptedPopup, let popupWebView = openPopup?(configuration, windowFeatures) {
#if DEBUG
            cmuxDebugLog("browser.nav.createWebView.action kind=popup")
#endif
            return popupWebView
        }

        // Fallback: open in new tab (no opener linkage)
        if let url = navigationAction.request.url {
            if let requestNavigation {
                let intent: BrowserInsecureHTTPNavigationIntent = .newTab
#if DEBUG
                cmuxDebugLog(
                    "browser.nav.createWebView.action kind=requestNavigation intent=newTab " +
                    "url=\(browserNavigationDebugURL(url))"
                )
#endif
                requestNavigation(navigationAction.request, intent)
            } else {
#if DEBUG
                cmuxDebugLog("browser.nav.createWebView.action kind=openInNewTab url=\(url.absoluteString)")
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
        presentDialog(
            alert,
            for: webView,
            completion: { _ in completionHandler() },
            cancel: completionHandler
        )
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
        presentDialog(
            alert,
            for: webView,
            completion: { response in
                completionHandler(response == .alertFirstButtonReturn)
            },
            cancel: {
                completionHandler(false)
            }
        )
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

        presentDialog(
            alert,
            for: webView,
            completion: { response in
                if response == .alertFirstButtonReturn {
                    completionHandler(field.stringValue)
                } else {
                    completionHandler(nil)
                }
            },
            cancel: {
                completionHandler(nil)
            }
        )
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

enum BrowserImportEngineFamily: String, Hashable, Sendable {
    case chromium
    case firefox
    case webkit
}

struct InstalledBrowserProfile: Identifiable, Hashable, Sendable {
    let displayName: String
    let rootURL: URL
    let isDefault: Bool

    var id: String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct BrowserImportBrowserDescriptor: Hashable, Sendable {
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

struct InstalledBrowserCandidate: Identifiable, Hashable, Sendable {
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

    @MainActor
    static func applicationBundleLookupSnapshot() -> [String: URL] {
        var result: [String: URL] = [:]
        for descriptor in allBrowserDescriptors {
            for bundleIdentifier in descriptor.bundleIdentifiers where result[bundleIdentifier] == nil {
                result[bundleIdentifier] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            }
        }
        return result
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

    var socketPayload: [String: Any] {
        [
            "browser": browserName,
            "scope": scope.rawValue,
            "domain_filters": domainFilters,
            "created_destination_profiles": createdDestinationProfileNames,
            "imported_cookies": totalImportedCookies,
            "skipped_cookies": totalSkippedCookies,
            "imported_history_entries": totalImportedHistoryEntries,
            "warnings": warnings,
            "entries": entries.map { entry in
                [
                    "source_profiles": entry.sourceProfileNames,
                    "destination_profile": entry.destinationProfileName,
                    "imported_cookies": entry.importedCookies,
                    "skipped_cookies": entry.skippedCookies,
                    "imported_history_entries": entry.importedHistoryEntries,
                    "warnings": entry.warnings,
                ] as [String: Any]
            },
        ]
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
        for (index, cookie) in cookies.enumerated() {
            if await setCookie(cookie, in: store) {
                importedCount += 1
            }
            if index > 0 && index.isMultiple(of: 50) {
                await Task.yield()
            }
        }
        return importedCount
    }

    @MainActor
    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async -> Bool {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume(returning: true)
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

    func presentImportDialog(
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) {
        presentImportDialog(
            prefilledBrowsers: nil,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        )
    }

    private struct ImportSelection {
        let browser: InstalledBrowserCandidate
        let executionPlan: BrowserImportExecutionPlan
        let scope: BrowserImportScope
        let domainFilters: [String]
    }

    private func presentImportDialog(
        prefilledBrowsers: [InstalledBrowserCandidate]?,
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?
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
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
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
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?
    ) -> ImportSelection? {
        guard !browsers.isEmpty else { return nil }
        let wizard = ImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        )
        return wizard.runModal()
    }

#if DEBUG
    func debugMakeImportWizardWindow(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]? = nil,
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) -> NSWindow {
        let wizard = ImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
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
        private let defaultScope: BrowserImportScope?

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
            defaultDestinationProfileID: UUID?,
            defaultScope: BrowserImportScope?
        ) {
            let resolvedDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
            let fallbackDestinationProfileID = resolvedDestinationProfiles.first?.id
                ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
            self.browsers = browsers
            self.destinationProfiles = resolvedDestinationProfiles
            self.initialDestinationProfileID = defaultDestinationProfileID
                .flatMap { candidateID in resolvedDestinationProfiles.first(where: { $0.id == candidateID })?.id }
                ?? fallbackDestinationProfileID
            self.defaultScope = defaultScope
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
            let initialScope = defaultScope ?? .cookiesAndHistory
            cookiesCheckbox.state = initialScope.includesCookies ? .on : .off
            historyCheckbox.state = initialScope.includesHistory ? .on : .off
            additionalDataCheckbox.state = initialScope == .everything ? .on : .off
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
