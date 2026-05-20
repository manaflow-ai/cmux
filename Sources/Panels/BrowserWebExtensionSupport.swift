import AppKit
import Foundation
import WebKit

struct BrowserWebExtensionInstalledSummary: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let detail: String
    let sourceKind: BrowserWebExtensionInstallRecord.SourceKind
    let sourcePath: String
    let grantedPermissions: [String]
    let grantedPermissionMatchPatterns: [String]
    let isEnabled: Bool
    let isLoaded: Bool
    let lastError: String?
}

struct BrowserWebExtensionActionSnapshot: Identifiable, Equatable {
    let id: UUID
    let label: String
    let badgeText: String
    let isEnabled: Bool
}

func browserWebExtensionAuxiliaryWindowContentRect(
    requestedFrame: CGRect,
    visibleFrame: NSRect,
    defaultSize: CGSize = CGSize(width: 420, height: 560),
    minSize: CGSize = CGSize(width: 260, height: 180)
) -> NSRect {
    let requestedWidth = requestedFrame.width.isFinite && requestedFrame.width > 0
        ? requestedFrame.width
        : nil
    let requestedHeight = requestedFrame.height.isFinite && requestedFrame.height > 0
        ? requestedFrame.height
        : nil
    let requestedX = requestedFrame.origin.x.isFinite ? requestedFrame.origin.x : nil
    let requestedY = requestedFrame.origin.y.isFinite ? requestedFrame.origin.y : nil

    let width = min(max(requestedWidth ?? defaultSize.width, minSize.width), visibleFrame.width)
    let height = min(max(requestedHeight ?? defaultSize.height, minSize.height), visibleFrame.height)
    let centeredX = visibleFrame.midX - width / 2
    let centeredY = visibleFrame.midY - height / 2
    let x = max(visibleFrame.minX, min(requestedX ?? centeredX, visibleFrame.maxX - width))
    let y = max(visibleFrame.minY, min(requestedY ?? centeredY, visibleFrame.maxY - height))
    return NSRect(x: x, y: y, width: width, height: height)
}

func browserWebExtensionActionPopupContentSize(
    requestedSize: CGSize,
    visibleFrame: NSRect,
    defaultSize: CGSize = CGSize(width: 380, height: 560),
    minSize: CGSize = CGSize(width: 260, height: 180),
    maxSize: CGSize = CGSize(width: 800, height: 600)
) -> CGSize {
    let maxWidth = max(minSize.width, min(maxSize.width, visibleFrame.width))
    let maxHeight = max(minSize.height, min(maxSize.height, visibleFrame.height))
    let requestedWidth = requestedSize.width.isFinite && requestedSize.width >= minSize.width
        ? requestedSize.width
        : nil
    let requestedHeight = requestedSize.height.isFinite && requestedSize.height >= minSize.height
        ? requestedSize.height
        : nil
    let width = min(max(requestedWidth ?? defaultSize.width, minSize.width), maxWidth)
    let height = min(max(requestedHeight ?? defaultSize.height, minSize.height), maxHeight)
    return CGSize(width: width, height: height)
}

func browserWebExtensionActionPopupPositioningRect(
    positioningRect: NSRect,
    positioningView: NSView,
    popupWidth: CGFloat,
    margin: CGFloat = 12
) -> NSRect {
    guard let anchorWindow = positioningView.window else {
        return positioningRect
    }

    let rectInWindow = positioningView.convert(positioningRect, to: nil)
    let screenRect = anchorWindow.convertToScreen(rectInWindow)
    let visibleFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? screenRect
    let hostFrame = anchorWindow.frame.intersection(visibleFrame)
    let allowedFrame = (hostFrame.isNull || hostFrame.isEmpty ? visibleFrame : hostFrame)
        .insetBy(dx: margin, dy: margin)
    guard allowedFrame.width > 0 else {
        return positioningRect
    }

    let effectiveWidth = min(max(popupWidth, 1), allowedFrame.width)
    let minMidX = allowedFrame.minX + effectiveWidth / 2
    let maxMidX = allowedFrame.maxX - effectiveWidth / 2
    let clampedMidX = min(max(screenRect.midX, minMidX), maxMidX)
    let adjustedScreenRect = screenRect.offsetBy(dx: clampedMidX - screenRect.midX, dy: 0)
    let adjustedWindowRect = anchorWindow.convertFromScreen(adjustedScreenRect)
    return positioningView.convert(adjustedWindowRect, from: nil)
}

func browserWebExtensionConfigureBaseWebViewConfiguration(
    _ configuration: WKWebViewConfiguration,
    defaultWebsiteDataStore: WKWebsiteDataStore
) {
    configuration.websiteDataStore = defaultWebsiteDataStore
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.applicationNameForUserAgent = BrowserUserAgentSettings.safariApplicationNameForUserAgent
}

enum BrowserExtensionDeveloperModeSettings {
    static let key = "browserExtensionsDeveloperMode"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

struct BrowserWebExtensionHostCapabilityPolicy: Equatable {
    static let current = BrowserWebExtensionHostCapabilityPolicy()

    func isPermissionGrantable(
        _ rawPermission: String,
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> Bool {
        _ = rawPermission
        return sourceKind == .appExtensionBundle
    }

    func grantablePermissionNames(
        from rawPermissions: [String],
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> [String] {
        guard sourceKind == .appExtensionBundle else { return [] }
        return Array(Set(rawPermissions)).sorted()
    }

    func unsupportedAPIs(
        forPermissionNames rawPermissions: [String],
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> Set<String> {
        _ = rawPermissions
        _ = sourceKind
        return []
    }
}

func browserWebExtensionHostGrantablePermissionNames(
    from rawPermissions: [String],
    sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
) -> [String] {
    BrowserWebExtensionHostCapabilityPolicy.current.grantablePermissionNames(
        from: rawPermissions,
        sourceKind: sourceKind
    )
}

@available(macOS 15.4, *)
func browserWebExtensionUnsupportedAPIs(
    for webExtension: WKWebExtension,
    sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
) -> Set<String> {
    let requestedPermissions = webExtension.requestedPermissions.map { String($0.rawValue) }
    let optionalPermissions = webExtension.optionalPermissions.map { String($0.rawValue) }
    return BrowserWebExtensionHostCapabilityPolicy.current.unsupportedAPIs(
        forPermissionNames: requestedPermissions + optionalPermissions,
        sourceKind: sourceKind
    )
}

struct BrowserWebExtensionInstallResult: Equatable {
    let summary: BrowserWebExtensionInstalledSummary
    let parseErrors: [String]
}

struct BrowserWebExtensionProfileState: Codable, Equatable {
    var isEnabled: Bool
    var grantedPermissions: [String]
    var grantedPermissionMatchPatterns: [String]
    var lastError: String?

    func sanitized(sourceKind: BrowserWebExtensionInstallRecord.SourceKind) -> BrowserWebExtensionProfileState {
        BrowserWebExtensionProfileState(
            isEnabled: isEnabled,
            grantedPermissions: browserWebExtensionHostGrantablePermissionNames(
                from: grantedPermissions,
                sourceKind: sourceKind
            ).sorted(),
            grantedPermissionMatchPatterns: grantedPermissionMatchPatterns.sorted(),
            lastError: lastError
        )
    }
}

struct BrowserWebExtensionInstallRecord: Codable, Equatable, Identifiable {
    enum SourceKind: String, Codable {
        case legacyResourceBaseURL = "resourceBaseURL"
        case appExtensionBundle
    }

    let id: UUID
    var displayName: String
    var displayVersion: String?
    var sourceKind: SourceKind
    var sourcePath: String
    var isEnabled: Bool
    var grantedPermissions: [String]
    var grantedPermissionMatchPatterns: [String]
    var profileStates: [String: BrowserWebExtensionProfileState]

    init(
        id: UUID,
        displayName: String,
        displayVersion: String?,
        sourceKind: SourceKind,
        sourcePath: String,
        isEnabled: Bool,
        grantedPermissions: [String],
        grantedPermissionMatchPatterns: [String],
        profileStates: [String: BrowserWebExtensionProfileState] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.displayVersion = displayVersion
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.isEnabled = isEnabled
        self.grantedPermissions = grantedPermissions
        self.grantedPermissionMatchPatterns = grantedPermissionMatchPatterns
        self.profileStates = profileStates
    }

    var defaultProfileState: BrowserWebExtensionProfileState {
        BrowserWebExtensionProfileState(
            isEnabled: isEnabled,
            grantedPermissions: grantedPermissions,
            grantedPermissionMatchPatterns: grantedPermissionMatchPatterns,
            lastError: nil
        )
    }

    func profileState(for profileID: UUID) -> BrowserWebExtensionProfileState {
        profileStates[Self.profileStateKey(for: profileID)] ?? defaultProfileState
    }

    mutating func setProfileState(_ state: BrowserWebExtensionProfileState, for profileID: UUID) {
        profileStates[Self.profileStateKey(for: profileID)] = state.sanitized(sourceKind: sourceKind)
    }

    static func profileStateKey(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case displayVersion
        case sourceKind
        case sourcePath
        case isEnabled
        case grantedPermissions
        case grantedPermissionMatchPatterns
        case profileStates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        displayVersion = try container.decodeIfPresent(String.self, forKey: .displayVersion)
        sourceKind = try container.decode(SourceKind.self, forKey: .sourceKind)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        grantedPermissions = try container.decode([String].self, forKey: .grantedPermissions)
        grantedPermissionMatchPatterns = try container.decode([String].self, forKey: .grantedPermissionMatchPatterns)
        profileStates = try container.decodeIfPresent(
            [String: BrowserWebExtensionProfileState].self,
            forKey: .profileStates
        ) ?? [:]
    }
}

struct BrowserWebExtensionInstallSource: Equatable {
    let kind: BrowserWebExtensionInstallRecord.SourceKind
    let url: URL
}

func browserWebExtensionSourceDescription(
    for sourceKind: BrowserWebExtensionInstallRecord.SourceKind
) -> String {
    switch sourceKind {
    case .appExtensionBundle:
        return String(localized: "browser.extensions.summary.appExtension", defaultValue: "Safari app extension")
    case .legacyResourceBaseURL:
        return String(localized: "browser.extensions.summary.unsupportedLocalExtension", defaultValue: "Unsupported legacy extension")
    }
}

func browserWebExtensionSummaryDetail(
    sourceKind: BrowserWebExtensionInstallRecord.SourceKind,
    displayVersion: String?
) -> String {
    let sourceDetail = browserWebExtensionSourceDescription(for: sourceKind)
    guard let version = displayVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
          !version.isEmpty else {
        return sourceDetail
    }
    let versionDetail = String(
        format: String(localized: "browser.extensions.summary.version", defaultValue: "Version %@"),
        version
    )
    return String(
        format: String(localized: "browser.extensions.summary.sourceWithVersion", defaultValue: "%@, %@"),
        sourceDetail,
        versionDetail
    )
}

func browserWebExtensionContextUniqueIdentifier(
    for record: BrowserWebExtensionInstallRecord,
    profileID: UUID
) -> String? {
    switch record.sourceKind {
    case .legacyResourceBaseURL:
        return nil
    case .appExtensionBundle:
        let bundleIdentifier = Bundle(url: URL(fileURLWithPath: record.sourcePath))?
            .bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        return "\(bundleIdentifier).cmux-profile.\(profileID.uuidString.lowercased())"
    }
}

enum BrowserWebExtensionInstallError: LocalizedError, Equatable {
    case unsupportedOS
    case cancelled
    case noManifest(URL)
    case noWebExtensionInApp(URL)
    case unsupportedSource(URL)
    case developerModeRequired(URL)
    case extensionNotFound(String)
    case ambiguousExtension(String)
    case loadFailed(String)
    case persistFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return String(localized: "browser.extensions.error.unsupportedOS", defaultValue: "Browser extensions require macOS 15.4 or later.")
        case .cancelled:
            return String(localized: "browser.extensions.error.cancelled", defaultValue: "Extension installation was cancelled.")
        case .noManifest(let url):
            return String(
                format: String(localized: "browser.extensions.error.noManifest", defaultValue: "No manifest.json was found in %@."),
                url.path
            )
        case .noWebExtensionInApp(let url):
            return String(
                format: String(localized: "browser.extensions.error.noWebExtensionInApp", defaultValue: "No Safari Web Extension was found in %@."),
                url.lastPathComponent
            )
        case .unsupportedSource(let url):
            return String(
                format: String(localized: "browser.extensions.error.unsupportedSource", defaultValue: "%@ is not an app or .appex containing a Safari Web Extension."),
                url.lastPathComponent
            )
        case .developerModeRequired(let url):
            return String(
                format: String(localized: "browser.extensions.error.developerModeRequired", defaultValue: "Developer Mode is required to load %@ directly. Install the containing app bundle instead, or enable Browser Extensions Developer Mode."),
                url.lastPathComponent
            )
        case .extensionNotFound(let query):
            return String(
                format: String(localized: "browser.extensions.error.notFound", defaultValue: "No installed browser extension matches '%@'."),
                query
            )
        case .ambiguousExtension(let query):
            return String(
                format: String(localized: "browser.extensions.error.ambiguous", defaultValue: "Multiple installed browser extensions match '%@'. Use the extension ID instead."),
                query
            )
        case .loadFailed(let message):
            return message
        case .persistFailed(let message):
            return message
        }
    }
}

final class BrowserWebExtensionInstallStore {
    private enum AppExtensionValidationResult: Equatable {
        case valid
        case missingManifest
        case missingInfoPlist
        case notSafariWebExtension
    }

    private static let safariWebExtensionPointIdentifier = "com.apple.Safari.web-extension"

    private let registryURL: URL
    private let fileManager: FileManager

    private(set) var records: [BrowserWebExtensionInstallRecord] = []

    init(
        registryURL: URL = BrowserWebExtensionInstallStore.defaultRegistryURL(),
        fileManager: FileManager = .default
    ) {
        self.registryURL = registryURL
        self.fileManager = fileManager
        reload()
    }

    static func defaultSupportDirectoryURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let namespace = normalizedBrowserHistoryNamespace(bundleIdentifier: bundleId)
        return appSupport
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("browser_extensions", isDirectory: true)
    }

    static func defaultRegistryURL() -> URL {
        defaultSupportDirectoryURL().appendingPathComponent("installed_extensions.json", isDirectory: false)
    }

    func reload() {
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: registryURL)
            let decoded = try JSONDecoder().decode([BrowserWebExtensionInstallRecord].self, from: data)
            records = decoded.compactMap(sanitizedRecord)
            if records != decoded {
                try? persist()
            }
        } catch {
            quarantineCorruptRegistry(after: error)
        }
    }

    func summaries(
        profileID: UUID,
        loadedRecordIDs: Set<UUID> = []
    ) -> [BrowserWebExtensionInstalledSummary] {
        records.map { record in
            let state = record.profileState(for: profileID)
            return BrowserWebExtensionInstalledSummary(
                id: record.id,
                displayName: record.displayName,
                detail: browserWebExtensionSummaryDetail(
                    sourceKind: record.sourceKind,
                    displayVersion: record.displayVersion
                ),
                sourceKind: record.sourceKind,
                sourcePath: record.sourcePath,
                grantedPermissions: state.grantedPermissions,
                grantedPermissionMatchPatterns: state.grantedPermissionMatchPatterns,
                isEnabled: state.isEnabled,
                isLoaded: loadedRecordIDs.contains(record.id),
                lastError: state.lastError
            )
        }
    }

    func installRecord(
        from source: BrowserWebExtensionInstallSource,
        displayName: String,
        displayVersion: String?,
        grantedPermissions: [String],
        grantedPermissionMatchPatterns: [String]
    ) throws -> BrowserWebExtensionInstallRecord {
        guard source.kind == .appExtensionBundle else {
            throw BrowserWebExtensionInstallError.unsupportedSource(source.url)
        }
        let recordID = existingRecordID(for: source) ?? UUID()
        let previousRecords = records

        let record = BrowserWebExtensionInstallRecord(
            id: recordID,
            displayName: displayName,
            displayVersion: displayVersion,
            sourceKind: source.kind,
            sourcePath: source.url.path,
            isEnabled: true,
            grantedPermissions: browserWebExtensionHostGrantablePermissionNames(
                from: grantedPermissions,
                sourceKind: source.kind
            ).sorted(),
            grantedPermissionMatchPatterns: grantedPermissionMatchPatterns.sorted()
        )

        var nextRecords = previousRecords
        if let index = nextRecords.firstIndex(where: { $0.id == recordID }) {
            nextRecords[index] = record
        } else {
            nextRecords.append(record)
        }
        nextRecords.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        do {
            try persist(nextRecords)
            records = nextRecords
        } catch {
            records = previousRecords
            try? persist(previousRecords)
            throw error
        }
        return record
    }

    func setEnabled(_ isEnabled: Bool, for recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var nextRecords = records
        nextRecords[index].isEnabled = isEnabled
        try persist(nextRecords)
        records = nextRecords
    }

    func setEnabled(_ isEnabled: Bool, for recordID: UUID, profileID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var nextRecords = records
        var state = nextRecords[index].profileState(for: profileID)
        state.isEnabled = isEnabled
        if isEnabled {
            state.lastError = nil
        }
        nextRecords[index].setProfileState(state, for: profileID)
        try persist(nextRecords)
        records = nextRecords
    }

    func setLastError(_ error: String?, for recordID: UUID, profileID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var nextRecords = records
        var state = nextRecords[index].profileState(for: profileID)
        let trimmedError = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.lastError = trimmedError?.isEmpty == false ? trimmedError : nil
        nextRecords[index].setProfileState(state, for: profileID)
        try persist(nextRecords)
        records = nextRecords
    }

    func remove(recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let previousRecords = records
        let record = previousRecords[index]
        var nextRecords = previousRecords
        nextRecords.remove(at: index)
        try persist(nextRecords)
        records = nextRecords
        _ = record
    }

    func discoverSource(
        from url: URL,
        developerModeEnabled: Bool = BrowserExtensionDeveloperModeSettings.isEnabled()
    ) throws -> BrowserWebExtensionInstallSource {
        let resolvedURL = url.standardizedFileURL
        let pathExtension = resolvedURL.pathExtension.lowercased()

        if pathExtension == "app" {
            guard let appExtensionURL = firstWebExtensionAppExtension(in: resolvedURL) else {
                throw BrowserWebExtensionInstallError.noWebExtensionInApp(resolvedURL)
            }
            return BrowserWebExtensionInstallSource(kind: .appExtensionBundle, url: appExtensionURL)
        }

        if pathExtension == "appex" {
            guard developerModeEnabled else {
                throw BrowserWebExtensionInstallError.developerModeRequired(resolvedURL)
            }
            switch appExtensionValidationResult(for: resolvedURL) {
            case .valid:
                return BrowserWebExtensionInstallSource(kind: .appExtensionBundle, url: resolvedURL)
            case .missingManifest:
                throw BrowserWebExtensionInstallError.noManifest(resolvedURL)
            case .missingInfoPlist:
                throw BrowserWebExtensionInstallError.noWebExtensionInApp(resolvedURL)
            case .notSafariWebExtension:
                throw BrowserWebExtensionInstallError.noWebExtensionInApp(resolvedURL)
            }
        }

        throw BrowserWebExtensionInstallError.unsupportedSource(resolvedURL)
    }

    private func existingRecordID(for source: BrowserWebExtensionInstallSource) -> UUID? {
        guard source.kind == .appExtensionBundle else { return nil }
        return records.first { record in
            record.sourceKind == source.kind && URL(fileURLWithPath: record.sourcePath).standardizedFileURL == source.url.standardizedFileURL
        }?.id
    }


    private func persist() throws {
        try persist(records)
    }

    private func persist(_ recordsToPersist: [BrowserWebExtensionInstallRecord]) throws {
        do {
            try fileManager.createDirectory(
                at: registryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.cmuxBrowserExtensions.encode(recordsToPersist)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            throw BrowserWebExtensionInstallError.persistFailed(error.localizedDescription)
        }
    }

    private func quarantineCorruptRegistry(after error: Error) {
        NSLog("[BrowserExtensions] Failed to reload extension registry: \(error.localizedDescription)")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = registryURL.deletingLastPathComponent()
            .appendingPathComponent("\(registryURL.deletingPathExtension().lastPathComponent).\(timestamp).corrupt.json")
        do {
            try fileManager.moveItem(at: registryURL, to: quarantineURL)
        } catch {
            NSLog("[BrowserExtensions] Failed to quarantine extension registry: \(error.localizedDescription)")
        }
    }

    private func sanitizedRecord(
        _ record: BrowserWebExtensionInstallRecord
    ) -> BrowserWebExtensionInstallRecord? {
        guard record.sourceKind == .appExtensionBundle else {
            return nil
        }
        var record = record
        record.grantedPermissions = browserWebExtensionHostGrantablePermissionNames(
            from: record.grantedPermissions,
            sourceKind: record.sourceKind
        ).sorted()
        record.grantedPermissionMatchPatterns = record.grantedPermissionMatchPatterns.sorted()
        record.profileStates = Dictionary(
            uniqueKeysWithValues: record.profileStates.map { key, state in
                (key, state.sanitized(sourceKind: record.sourceKind))
            }
        )
        return record
    }

    private func firstWebExtensionAppExtension(in appURL: URL) -> URL? {
        let pluginsURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let validAppExtensions = children
            .filter { $0.pathExtension.lowercased() == "appex" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .filter { appExtensionValidationResult(for: $0) == .valid }
        guard validAppExtensions.count == 1 else {
            return nil
        }
        return validAppExtensions[0]
    }

    private func appExtensionValidationResult(for appexURL: URL) -> AppExtensionValidationResult {
        guard appExtensionHasManifest(appexURL) else {
            return .missingManifest
        }

        guard appExtensionInfoPlistExists(appexURL) else {
            return .missingInfoPlist
        }

        guard appExtensionPointIdentifier(in: appexURL) == Self.safariWebExtensionPointIdentifier else {
            return .notSafariWebExtension
        }
        return .valid
    }

    private func appExtensionHasManifest(_ appexURL: URL) -> Bool {
        fileManager.fileExists(
            atPath: appexURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("manifest.json", isDirectory: false)
                .path
        )
    }

    private func appExtensionInfoPlistExists(_ appexURL: URL) -> Bool {
        fileManager.fileExists(atPath: appExtensionInfoPlistURL(for: appexURL).path)
    }

    private func appExtensionPointIdentifier(in appexURL: URL) -> String? {
        guard let data = try? Data(contentsOf: appExtensionInfoPlistURL(for: appexURL)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let extensionDictionary = dictionary["NSExtension"] as? [String: Any] else {
            return nil
        }
        return extensionDictionary["NSExtensionPointIdentifier"] as? String
    }

    private func appExtensionInfoPlistURL(for appexURL: URL) -> URL {
        appexURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
    }

}

private extension JSONEncoder {
    static var cmuxBrowserExtensions: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@MainActor
enum BrowserWebExtensionSupport {
    static let didChangeNotification = Notification.Name("cmux.browserWebExtensions.didChange")

    static var isAvailable: Bool {
        if #available(macOS 15.4, *) {
            return true
        }
        return false
    }

    static func configureWebViewConfiguration(
        _ configuration: WKWebViewConfiguration,
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.configure(
            configuration,
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
    }

    static func register(panel: BrowserPanel) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.register(panel: panel)
    }

    static func unregister(panel: BrowserPanel) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.unregister(panelID: panel.id)
    }

    static func unregister(panelID: UUID) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.unregister(panelID: panelID)
    }

    static func installedExtensionSummaries(
        profileID: UUID? = nil
    ) -> [BrowserWebExtensionInstalledSummary] {
        guard #available(macOS 15.4, *) else { return [] }
        let resolvedProfileID = profileID ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return BrowserWebExtensionRuntime.shared.installedExtensionSummaries(profileID: resolvedProfileID)
    }

    static func actionSnapshots(for panel: BrowserPanel) -> [BrowserWebExtensionActionSnapshot] {
        guard #available(macOS 15.4, *) else { return [] }
        return BrowserWebExtensionRuntime.shared.actionSnapshots(for: panel)
    }

    static func performAction(_ actionID: UUID, for panel: BrowserPanel) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.performAction(actionID, for: panel)
    }

    static func setActionPopupAnchorView(_ view: NSView?, forPanelID panelID: UUID) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.setActionPopupAnchorView(view, forPanelID: panelID)
    }

    static func installExtension(from url: URL) async throws -> BrowserWebExtensionInstallResult {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionInstallError.unsupportedOS
        }
        return try await BrowserWebExtensionRuntime.shared.installExtension(from: url)
    }

    static func reloadInstalledExtensions() async {
        guard #available(macOS 15.4, *) else { return }
        await BrowserWebExtensionRuntime.shared.reloadInstalledExtensions()
    }

    static func reloadExtension(
        id: UUID,
        profileID: UUID? = nil
    ) async throws -> BrowserWebExtensionInstalledSummary {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionInstallError.unsupportedOS
        }
        let resolvedProfileID = profileID ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return try await BrowserWebExtensionRuntime.shared.reloadExtension(id: id, profileID: resolvedProfileID)
    }

    static func setExtensionEnabled(
        _ isEnabled: Bool,
        id: UUID,
        profileID: UUID? = nil
    ) async throws -> BrowserWebExtensionInstalledSummary {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionInstallError.unsupportedOS
        }
        let resolvedProfileID = profileID ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return try await BrowserWebExtensionRuntime.shared.setExtensionEnabled(
            isEnabled,
            id: id,
            profileID: resolvedProfileID
        )
    }

    static func removeExtension(id: UUID) throws {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionInstallError.unsupportedOS
        }
        try BrowserWebExtensionRuntime.shared.removeExtension(id: id)
    }

    static func resolveExtensionID(matching query: String) throws -> UUID {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionInstallError.unsupportedOS
        }
        return try BrowserWebExtensionRuntime.shared.resolveExtensionID(matching: query)
    }

    static func notePanelPropertiesChanged(panel: BrowserPanel) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.notePanelPropertiesChanged(panel: panel)
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionWeakView {
    weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {
    static let shared = BrowserWebExtensionRuntime()

    private let store = BrowserWebExtensionInstallStore()
    private var controllersByProfileID: [UUID: WKWebExtensionController] = [:]
    private var contextsByProfileID: [UUID: [UUID: WKWebExtensionContext]] = [:]
    private var tabAdaptersByPanelID: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var auxiliaryWindowAdaptersByID: [UUID: BrowserWebExtensionAuxiliaryWindowAdapter] = [:]
    private var actionPopupPresentationsByID: [UUID: BrowserWebExtensionActionPopupPresentation] = [:]
    private var actionPopupAnchorViewsByPanelID: [UUID: BrowserWebExtensionWeakView] = [:]
    private var windowAdaptersByProfileID: [UUID: BrowserWebExtensionWindowAdapter] = [:]
    private var loadedProfileIDs: Set<UUID> = []

    override init() {
        super.init()
    }

    func configure(
        _ configuration: WKWebViewConfiguration,
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) {
        let controller = ensureController(
            profileID: profileID,
            defaultWebsiteDataStore: websiteDataStore
        )
        configuration.webExtensionController = controller
    }

    func register(panel: BrowserPanel) {
        let profileID = panel.profileID
        let controller = ensureController(
            profileID: profileID,
            defaultWebsiteDataStore: panel.websiteDataStore
        )
        let windowAdapter = ensureWindowAdapter(profileID: profileID)
        let existingAdapter = tabAdaptersByPanelID[panel.id]
        if let existingAdapter, existingAdapter.profileID != profileID {
            controllersByProfileID[existingAdapter.profileID]?.didCloseTab(existingAdapter, windowIsClosing: false)
            tabAdaptersByPanelID[panel.id] = nil
        }
        let adapter = tabAdaptersByPanelID[panel.id]
            ?? BrowserWebExtensionTabAdapter(
                panel: panel,
                windowAdapter: windowAdapter,
                profileID: profileID
            )
        adapter.panel = panel
        tabAdaptersByPanelID[panel.id] = adapter
        if existingAdapter == nil || existingAdapter?.profileID != profileID {
            controller.didOpenTab(adapter)
        }
        controller.didFocusWindow(windowAdapter)
        controller.didChangeTabProperties(WKWebExtension.TabChangedProperties([.title, .URL, .loading]), for: adapter)
        Task { @MainActor [weak self] in
            await self?.loadInstalledRecordsIfNeeded(profileID: profileID)
        }
        postDidChange()
    }

    func unregister(panelID: UUID) {
        guard let adapter = tabAdaptersByPanelID.removeValue(forKey: panelID) else { return }
        actionPopupAnchorViewsByPanelID.removeValue(forKey: panelID)
        controllersByProfileID[adapter.profileID]?.didCloseTab(adapter, windowIsClosing: false)
        postDidChange()
    }

    func installedExtensionSummaries(profileID: UUID) -> [BrowserWebExtensionInstalledSummary] {
        store.summaries(
            profileID: profileID,
            loadedRecordIDs: Set(contextsByProfileID[profileID, default: [:]].keys)
        )
    }

    func actionSnapshots(for panel: BrowserPanel) -> [BrowserWebExtensionActionSnapshot] {
        guard let tab = tabAdaptersByPanelID[panel.id] else { return [] }
        return contextsByProfileID[panel.profileID, default: [:]].compactMap { recordID, context in
            guard let action = context.action(for: tab) else { return nil }
            return BrowserWebExtensionActionSnapshot(
                id: recordID,
                label: action.label,
                badgeText: action.badgeText,
                isEnabled: action.isEnabled
            )
        }
        .sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    func performAction(_ actionID: UUID, for panel: BrowserPanel) {
        guard let context = contextsByProfileID[panel.profileID]?[actionID] else {
            return
        }
        let tab = tabAdaptersByPanelID[panel.id]
        context.performAction(for: tab)
    }

    func setActionPopupAnchorView(_ view: NSView?, forPanelID panelID: UUID) {
        guard let view else {
            actionPopupAnchorViewsByPanelID.removeValue(forKey: panelID)
            return
        }
        actionPopupAnchorViewsByPanelID[panelID] = BrowserWebExtensionWeakView(view)
    }

    func notePanelPropertiesChanged(panel: BrowserPanel) {
        guard let tab = tabAdaptersByPanelID[panel.id] else { return }
        controllersByProfileID[tab.profileID]?.didChangeTabProperties([.title, .URL, .loading], for: tab)
        postDidChange()
    }

    func installExtension(from url: URL) async throws -> BrowserWebExtensionInstallResult {
        let source = try store.discoverSource(from: url)
        let webExtension = try await loadWebExtension(from: source)
        let parseErrors = webExtension.errors.map(\.localizedDescription)
        let fatalParseErrors = webExtension.errors.filter { error in
            let nsError = error as NSError
            let code = WKWebExtension.Error.Code(rawValue: nsError.code)
            return nsError.domain == WKWebExtension.errorDomain &&
                code != .invalidManifestEntry &&
                code != .invalidDeclarativeNetRequestEntry &&
                code != .invalidBackgroundPersistence
        }
        if let firstError = fatalParseErrors.first {
            throw BrowserWebExtensionInstallError.loadFailed(firstError.localizedDescription)
        }
        try await promptForInstallConsent(webExtension: webExtension, sourceKind: source.kind)

        let record = try store.installRecord(
            from: source,
            displayName: webExtension.displayName ?? url.deletingPathExtension().lastPathComponent,
            displayVersion: webExtension.displayVersion ?? webExtension.version,
            grantedPermissions: webExtension.requestedPermissions.map { String($0.rawValue) },
            grantedPermissionMatchPatterns: requiredMatchPatternStrings(for: webExtension)
        )
        let activeProfileID = BrowserProfileStore.shared.effectiveLastUsedProfileID
        try await load(record: record, profileID: activeProfileID)
        postDidChange()
        let summary = store.summaries(
            profileID: activeProfileID,
            loadedRecordIDs: Set(contextsByProfileID[activeProfileID, default: [:]].keys)
        ).first { $0.id == record.id }
            ?? BrowserWebExtensionInstalledSummary(
                id: record.id,
                displayName: record.displayName,
                detail: browserWebExtensionSummaryDetail(
                    sourceKind: record.sourceKind,
                    displayVersion: record.displayVersion
                ),
                sourceKind: record.sourceKind,
                sourcePath: record.sourcePath,
                grantedPermissions: record.profileState(for: activeProfileID).grantedPermissions,
                grantedPermissionMatchPatterns: record.profileState(for: activeProfileID).grantedPermissionMatchPatterns,
                isEnabled: record.profileState(for: activeProfileID).isEnabled,
                isLoaded: contextsByProfileID[activeProfileID]?[record.id] != nil,
                lastError: record.profileState(for: activeProfileID).lastError
            )
        return BrowserWebExtensionInstallResult(summary: summary, parseErrors: parseErrors)
    }

    func reloadInstalledExtensions() async {
        closeAllActionPopups()
        closeAllAuxiliaryWindows()
        for (profileID, contextsByRecordID) in contextsByProfileID {
            guard let controller = controllersByProfileID[profileID] else { continue }
            for context in contextsByRecordID.values {
                try? controller.unload(context)
            }
        }
        contextsByProfileID.removeAll()
        loadedProfileIDs.removeAll()
        store.reload()
        for profileID in controllersByProfileID.keys {
            await loadInstalledRecordsIfNeeded(profileID: profileID)
        }
        postDidChange()
    }

    func reloadExtension(id: UUID, profileID: UUID) async throws -> BrowserWebExtensionInstalledSummary {
        guard let record = store.records.first(where: { $0.id == id }) else {
            throw BrowserWebExtensionInstallError.extensionNotFound(id.uuidString)
        }
        let state = record.profileState(for: profileID)
        guard state.isEnabled else {
            return try summary(for: id, profileID: profileID)
        }
        try await load(record: record, profileID: profileID)
        postDidChange()
        return try summary(for: id, profileID: profileID)
    }

    func setExtensionEnabled(
        _ isEnabled: Bool,
        id: UUID,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstalledSummary {
        try store.setEnabled(isEnabled, for: id, profileID: profileID)
        if isEnabled, let record = store.records.first(where: { $0.id == id }) {
            try await load(record: record, profileID: profileID)
        } else {
            unload(recordID: id, profileID: profileID)
        }
        postDidChange()
        return try summary(for: id, profileID: profileID)
    }

    func removeExtension(id: UUID) throws {
        closeAllActionPopups()
        for profileID in controllersByProfileID.keys {
            unload(recordID: id, profileID: profileID)
        }
        try store.remove(recordID: id)
        postDidChange()
    }

    func resolveExtensionID(matching query: String) throws -> UUID {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed),
           store.records.contains(where: { $0.id == uuid }) {
            return uuid
        }
        let matches = store.records.filter { record in
            record.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame ||
                URL(fileURLWithPath: record.sourcePath).lastPathComponent.localizedCaseInsensitiveCompare(trimmed) == .orderedSame ||
                (Bundle(url: URL(fileURLWithPath: record.sourcePath))?.bundleIdentifier?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame)
        }
        if matches.count > 1 {
            throw BrowserWebExtensionInstallError.ambiguousExtension(query)
        }
        guard let match = matches.first else {
            throw BrowserWebExtensionInstallError.extensionNotFound(query)
        }
        return match.id
    }

    private func summary(for recordID: UUID, profileID: UUID) throws -> BrowserWebExtensionInstalledSummary {
        guard let summary = installedExtensionSummaries(profileID: profileID).first(where: { $0.id == recordID }) else {
            throw BrowserWebExtensionInstallError.extensionNotFound(recordID.uuidString)
        }
        return summary
    }

    private func ensureController(
        profileID: UUID,
        defaultWebsiteDataStore: WKWebsiteDataStore
    ) -> WKWebExtensionController {
        if let controller = controllersByProfileID[profileID] {
            return controller
        }

        let baseConfiguration = WKWebViewConfiguration()
        browserWebExtensionConfigureBaseWebViewConfiguration(
            baseConfiguration,
            defaultWebsiteDataStore: defaultWebsiteDataStore
        )

        let configuration = WKWebExtensionController.Configuration.default()
        configuration.webViewConfiguration = baseConfiguration
        configuration.defaultWebsiteDataStore = defaultWebsiteDataStore

        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        controllersByProfileID[profileID] = controller

        Task { @MainActor [weak self] in
            await self?.loadInstalledRecordsIfNeeded(profileID: profileID)
        }

        return controller
    }

    private func ensureWindowAdapter(profileID: UUID) -> BrowserWebExtensionWindowAdapter {
        if let adapter = windowAdaptersByProfileID[profileID] {
            return adapter
        }
        let adapter = BrowserWebExtensionWindowAdapter(profileID: profileID)
        adapter.runtime = self
        windowAdaptersByProfileID[profileID] = adapter
        return adapter
    }

    private func profileID(for controller: WKWebExtensionController) -> UUID? {
        controllersByProfileID.first { $0.value === controller }?.key
    }

    private func profileID(for context: WKWebExtensionContext) -> UUID? {
        for (profileID, contexts) in contextsByProfileID {
            if contexts.values.contains(where: { $0 === context }) {
                return profileID
            }
        }
        return nil
    }

    private func auxiliaryWebViewConfiguration(
        initialURL: URL?,
        context: WKWebExtensionContext,
        openerPanel: BrowserPanel?,
        shouldBePrivate: Bool
    ) -> WKWebViewConfiguration? {
        let configuration: WKWebViewConfiguration
        if let initialURL,
           let targetContext = context.webExtensionController?.extensionContext(for: initialURL),
           targetContext === context {
            guard let extensionConfiguration = context.webViewConfiguration else { return nil }
            configuration = extensionConfiguration
        } else {
            configuration = WKWebViewConfiguration()
            if let browserContext = openerPanel?.popupBrowserContext {
                BrowserPanel.configureWebViewConfiguration(
                    configuration,
                    profileID: browserContext.profileID,
                    websiteDataStore: browserContext.websiteDataStore,
                    processPool: browserContext.processPool
                )
            } else {
                let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
                BrowserPanel.configureWebViewConfiguration(
                    configuration,
                    profileID: defaultProfileID,
                    websiteDataStore: .default()
                )
            }
        }

        if shouldBePrivate {
            configuration.websiteDataStore = .nonPersistent()
        }
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    private func loadInstalledRecordsIfNeeded(profileID: UUID) async {
        guard !loadedProfileIDs.contains(profileID) else { return }
        loadedProfileIDs.insert(profileID)
        for record in store.records where record.profileState(for: profileID).isEnabled {
            do {
                try await load(record: record, profileID: profileID)
            } catch {
                try? store.setLastError(error.localizedDescription, for: record.id, profileID: profileID)
            }
        }
        postDidChange()
    }

    private func load(record: BrowserWebExtensionInstallRecord, profileID: UUID) async throws {
        let dataStore = BrowserProfileStore.shared.websiteDataStore(for: profileID)
        let controller = ensureController(
            profileID: profileID,
            defaultWebsiteDataStore: dataStore
        )
        if let existing = contextsByProfileID[profileID]?[record.id] {
            try? controller.unload(existing)
            contextsByProfileID[profileID]?[record.id] = nil
        }

        let source = BrowserWebExtensionInstallSource(
            kind: record.sourceKind,
            url: URL(fileURLWithPath: record.sourcePath)
        )
        let webExtension = try await loadWebExtension(from: source)
        let context = WKWebExtensionContext(for: webExtension)
        if let uniqueIdentifier = browserWebExtensionContextUniqueIdentifier(for: record, profileID: profileID) {
            context.uniqueIdentifier = uniqueIdentifier
        }
        context.inspectionName = record.displayName
#if DEBUG
        context.isInspectable = true
#endif
        context.unsupportedAPIs = browserWebExtensionUnsupportedAPIs(
            for: webExtension,
            sourceKind: record.sourceKind
        )
        let profileState = record.profileState(for: profileID)
        for rawPermission in browserWebExtensionHostGrantablePermissionNames(
            from: profileState.grantedPermissions,
            sourceKind: record.sourceKind
        ) {
            context.setPermissionStatus(
                .grantedExplicitly,
                for: WKWebExtension.Permission(rawPermission)
            )
        }
        for rawPattern in profileState.grantedPermissionMatchPatterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: rawPattern) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
        contextsByProfileID[profileID, default: [:]][record.id] = context
        do {
            try controller.load(context)
        } catch {
            contextsByProfileID[profileID]?[record.id] = nil
            try? store.setLastError(error.localizedDescription, for: record.id, profileID: profileID)
            throw error
        }
        try? store.setLastError(nil, for: record.id, profileID: profileID)
        if webExtension.hasBackgroundContent {
            Task { @MainActor [weak self] in
                do {
                    try await context.loadBackgroundContent()
                } catch {
#if DEBUG
                    cmuxDebugLog(
                        "browser.extensions.background.loadFailed label=\(record.displayName) error=\(error.localizedDescription)"
                    )
#endif
                    try? self?.store.setLastError(
                        error.localizedDescription,
                        for: record.id,
                        profileID: profileID
                    )
                    self?.postDidChange()
                }
            }
        }
    }

    private func unload(recordID: UUID, profileID: UUID) {
        guard let context = contextsByProfileID[profileID]?[recordID] else { return }
        try? controllersByProfileID[profileID]?.unload(context)
        contextsByProfileID[profileID]?[recordID] = nil
    }

    private func loadWebExtension(from source: BrowserWebExtensionInstallSource) async throws -> WKWebExtension {
        do {
            switch source.kind {
            case .legacyResourceBaseURL:
                throw BrowserWebExtensionInstallError.unsupportedSource(source.url)
            case .appExtensionBundle:
                guard let bundle = Bundle(url: source.url) else {
                    throw BrowserWebExtensionInstallError.unsupportedSource(source.url)
                }
                return try await WKWebExtension(appExtensionBundle: bundle)
            }
        } catch let installError as BrowserWebExtensionInstallError {
            throw installError
        } catch {
            throw BrowserWebExtensionInstallError.loadFailed(error.localizedDescription)
        }
    }

    private func promptForInstallConsent(
        webExtension: WKWebExtension,
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind
    ) async throws {
        let alert = NSAlert()
        alert.messageText = String(localized: "browser.extensions.install.title", defaultValue: "Install Browser Extension?")
        alert.informativeText = installConsentMessage(webExtension, sourceKind: sourceKind)
        alert.addButton(withTitle: String(localized: "browser.extensions.install.confirm", defaultValue: "Install"))
        alert.addButton(withTitle: String(localized: "browser.extensions.install.cancel", defaultValue: "Cancel"))
        alert.alertStyle = .informational
        let response = await runModal(alert)
        guard response == .alertFirstButtonReturn else {
            throw BrowserWebExtensionInstallError.cancelled
        }
    }

    private func installConsentMessage(
        _ webExtension: WKWebExtension,
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind
    ) -> String {
        let extensionName = webExtension.displayName
            ?? String(localized: "browser.extensions.unknownExtension", defaultValue: "Unknown extension")
        let permissions = browserWebExtensionHostGrantablePermissionNames(
            from: webExtension.requestedPermissions.map { String($0.rawValue) },
            sourceKind: sourceKind
        )
            .sorted()
            .joined(separator: ", ")
        let hosts = requiredMatchPatternStrings(for: webExtension)
            .joined(separator: ", ")
        let permissionsLine = permissions.isEmpty
            ? String(localized: "browser.extensions.install.noAPIPermissions", defaultValue: "No API permissions")
            : permissions
        let hostsLine = hosts.isEmpty
            ? String(localized: "browser.extensions.install.noWebsiteAccess", defaultValue: "No website access")
            : hosts
        return String(
            format: String(
                localized: "browser.extensions.install.message",
                defaultValue: "%@\n\nSource: %@\nAPI permissions: %@\nWebsite access: %@\n\ncmux grants only these permissions and lets WebKit enforce extension isolation, host access, and runtime permission prompts."
            ),
            extensionName,
            browserWebExtensionSourceDescription(for: sourceKind),
            permissionsLine,
            hostsLine
        )
    }

    private func runModal(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        }
        return alert.runModal()
    }

    private func requiredMatchPatternStrings(for webExtension: WKWebExtension) -> [String] {
        let requestedPatterns = webExtension.requestedPermissionMatchPatterns.map(\.string)
        let injectedContentPatterns = webExtension.allRequestedMatchPatterns.map(\.string)
        return Array(Set(requestedPatterns + injectedContentPatterns)).sorted()
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: BrowserWebExtensionSupport.didChangeNotification, object: nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        let profileID = profileID(for: controller)
        let auxiliaryWindows = auxiliaryWindowAdaptersByID.values
            .filter { profileID == nil || $0.profileID == profileID }
            .filter(\.isVisible)
            .sorted { $0.createdAt < $1.createdAt }
        let windowAdapter = profileID.map { ensureWindowAdapter(profileID: $0) }
        if let focusedAuxiliaryWindow = auxiliaryWindows.first(where: \.isKeyWindow) {
            var windows: [any WKWebExtensionWindow] = [focusedAuxiliaryWindow]
            if let windowAdapter {
                windows.append(windowAdapter)
            }
            windows.append(contentsOf: auxiliaryWindows.filter { $0 !== focusedAuxiliaryWindow })
            return windows
        }
        var windows: [any WKWebExtensionWindow] = []
        if let windowAdapter {
            windows.append(windowAdapter)
        }
        windows.append(contentsOf: auxiliaryWindows)
        return windows
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        let profileID = profileID(for: controller)
        if let focusedAuxiliaryWindow = auxiliaryWindowAdaptersByID.values.first(where: {
            $0.isKeyWindow && (profileID == nil || $0.profileID == profileID)
        }) {
            return focusedAuxiliaryWindow
        }
        let window = profileID.map { ensureWindowAdapter(profileID: $0) }
        return window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        let profileID = profileID(for: controller) ?? BrowserProfileStore.shared.builtInDefaultProfileID
        let opener = configuration.tabs.compactMap { ($0 as? BrowserWebExtensionTabAdapter)?.panel }.first
            ?? activeTabAdapter(profileID: profileID)?.panel
            ?? tabAdaptersByPanelID.values.filter { $0.profileID == profileID }.compactMap(\.panel).first
        let initialURL = configuration.tabURLs.first
        guard let webViewConfiguration = auxiliaryWebViewConfiguration(
            initialURL: initialURL,
            context: context,
            openerPanel: opener,
            shouldBePrivate: configuration.shouldBePrivate
        ) else {
            completionHandler(nil, nil)
            return
        }

        let window = BrowserWebExtensionAuxiliaryWindowAdapter(
            runtime: self,
            profileID: profileID,
            configuration: configuration,
            webViewConfiguration: webViewConfiguration,
            customUserAgent: BrowserUserAgentSettings.safariUserAgent,
            initialURL: initialURL,
            openerPanel: opener
        )
        auxiliaryWindowAdaptersByID[window.id] = window
        controller.didOpenWindow(window)
        controller.didOpenTab(window.tabAdapter)
        if configuration.shouldBeFocused {
            controller.didFocusWindow(window)
        }
        postDidChange()
        completionHandler(window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        let profileID = profileID(for: controller) ?? BrowserProfileStore.shared.builtInDefaultProfileID
        let opener = (configuration.parentTab as? BrowserWebExtensionTabAdapter)?.panel
            ?? activeTabAdapter(profileID: profileID)?.panel
            ?? tabAdaptersByPanelID.values.filter { $0.profileID == profileID }.compactMap(\.panel).first
        guard let opener,
              let app = AppDelegate.shared,
              let workspace = app.workspaceContainingPanel(
                panelId: opener.id,
                preferredWorkspaceId: opener.workspaceId
              )?.workspace,
              let paneId = workspace.paneId(forPanelId: opener.id) else {
            completionHandler(nil, nil)
            return
        }
        let createdPanel = workspace.newBrowserSurface(
            inPane: paneId,
            url: configuration.url,
            focus: configuration.shouldBeActive,
            insertAtEnd: true,
            preferredProfileID: opener.profileID
        )
        if let createdPanel {
            register(panel: createdPanel)
        }
        completionHandler(createdPanel.flatMap { tabAdaptersByPanelID[$0.id] }, nil)
    }

    fileprivate func auxiliaryWindowDidFocus(_ window: BrowserWebExtensionAuxiliaryWindowAdapter) {
        controllersByProfileID[window.profileID]?.didFocusWindow(window)
    }

    fileprivate func auxiliaryWindowDidChangeTabProperties(
        _ properties: WKWebExtension.TabChangedProperties,
        tab: BrowserWebExtensionAuxiliaryTabAdapter
    ) {
        controllersByProfileID[tab.profileID]?.didChangeTabProperties(properties, for: tab)
    }

    fileprivate func auxiliaryWindowDidClose(_ window: BrowserWebExtensionAuxiliaryWindowAdapter) {
        auxiliaryWindowAdaptersByID.removeValue(forKey: window.id)
        controllersByProfileID[window.profileID]?.didCloseTab(window.tabAdapter, windowIsClosing: true)
        controllersByProfileID[window.profileID]?.didCloseWindow(window)
        postDidChange()
    }

    private func closeAllAuxiliaryWindows() {
        let windows = Array(auxiliaryWindowAdaptersByID.values)
        for window in windows {
            window.closeWindow()
        }
    }

    fileprivate func actionPopupDidClose(_ presentation: BrowserWebExtensionActionPopupPresentation) {
        actionPopupPresentationsByID.removeValue(forKey: presentation.id)
    }

    private func closeAllActionPopups() {
        let presentations = Array(actionPopupPresentationsByID.values)
        for presentation in presentations {
            presentation.close()
        }
        actionPopupPresentationsByID.removeAll()
    }

    private func showActionPopup(
        _ action: WKWebExtension.Action,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let popupPopover = action.popupPopover
        let fallbackAnchorView = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel?.webView
            ?? activeTabAdapter()?.panel?.webView
        guard action.isEnabled,
              action.presentsPopup,
              let popupWebView = action.popupWebView,
              let fallbackAnchorView else {
            completionHandler(nil)
            return
        }
#if DEBUG
        popupWebView.isInspectable = true
#endif
        let sourceAnchorView = actionPopupAnchorView(for: action) ?? fallbackAnchorView
        let presentationAnchorView = sourceAnchorView.window?.contentView ?? sourceAnchorView
        let rectInWindow = sourceAnchorView.convert(sourceAnchorView.bounds, to: nil)
        let rect = presentationAnchorView.convert(rectInWindow, from: nil)
        closeAllActionPopups()
        let presentation = BrowserWebExtensionActionPopupPresentation(
            action: action,
            popupWebView: popupWebView,
            requestedContentSize: popupPopover?.contentSize ?? .zero,
            runtime: self
        )
        actionPopupPresentationsByID[presentation.id] = presentation
        presentation.show(
            relativeTo: rect,
            of: presentationAnchorView,
            preferredEdge: .minY
        )
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let sourceKind = sourceKind(for: context)
        let grantablePermissions = Set(permissions.filter {
            BrowserWebExtensionHostCapabilityPolicy.current.isPermissionGrantable(
                String($0.rawValue),
                sourceKind: sourceKind
            )
        })
        guard !grantablePermissions.isEmpty else {
            completionHandler([], nil)
            return
        }
        let message = grantablePermissions.map { String($0.rawValue) }.sorted().joined(separator: ", ")
        promptForRuntimePermission(message: message) { allowed in
            completionHandler(allowed ? grantablePermissions : [], nil)
        }
    }

    private func sourceKind(for context: WKWebExtensionContext) -> BrowserWebExtensionInstallRecord.SourceKind {
        guard let profileID = profileID(for: context),
              let recordID = contextsByProfileID[profileID]?.first(where: { $0.value === context })?.key,
              let record = store.records.first(where: { $0.id == recordID }) else {
            return .appExtensionBundle
        }
        return record.sourceKind
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let message = urls.map(\.absoluteString).sorted().joined(separator: ", ")
        promptForRuntimePermission(message: message) { allowed in
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let message = matchPatterns.map(\.string).sorted().joined(separator: ", ")
        promptForRuntimePermission(message: message) { allowed in
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        postDidChange()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        showActionPopup(action, completionHandler: completionHandler)
    }

    private func actionPopupAnchorView(for action: WKWebExtension.Action) -> NSView? {
        guard let panelID = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel?.id
            ?? activeTabAdapter()?.panel?.id,
            let view = actionPopupAnchorViewsByPanelID[panelID]?.view,
            view.window != nil
        else {
            return nil
        }
        return view
    }

    private func promptForRuntimePermission(
        message: String,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "browser.extensions.permission.title", defaultValue: "Allow Extension Permission?")
        alert.informativeText = String(
            format: String(localized: "browser.extensions.permission.message", defaultValue: "An extension is asking for access to:\n\n%@"),
            message
        )
        alert.addButton(withTitle: String(localized: "browser.extensions.permission.allow", defaultValue: "Allow"))
        alert.addButton(withTitle: String(localized: "browser.extensions.permission.deny", defaultValue: "Deny"))
        alert.alertStyle = .informational
        Task { @MainActor in
            let response = await runModal(alert)
            completion(response == .alertFirstButtonReturn)
        }
    }

    fileprivate func activeTabAdapter(profileID: UUID? = nil) -> BrowserWebExtensionTabAdapter? {
        if let focusedPanelID = AppDelegate.shared?.tabManager?.selectedWorkspace?.focusedPanelId,
           let adapter = tabAdaptersByPanelID[focusedPanelID],
           profileID == nil || adapter.profileID == profileID {
            return adapter
        }
        return tabAdaptersByPanelID.values.first { adapter in
            guard profileID == nil || adapter.profileID == profileID else { return false }
            return adapter.panel?.webView.window?.isKeyWindow == true
        }
    }

    fileprivate func tabAdapters(profileID: UUID) -> [BrowserWebExtensionTabAdapter] {
        var seenPanelIDs: Set<UUID> = []
        var orderedAdapters: [BrowserWebExtensionTabAdapter] = []

        if let tabManager = AppDelegate.shared?.tabManager {
            for workspace in tabManager.tabs {
                for panelID in workspace.sidebarOrderedPanelIds() where seenPanelIDs.insert(panelID).inserted {
                    if let adapter = tabAdaptersByPanelID[panelID],
                       adapter.profileID == profileID {
                        orderedAdapters.append(adapter)
                    }
                }
            }
        }

        let fallbackPanelIDs = tabAdaptersByPanelID.keys.sorted { $0.uuidString < $1.uuidString }
        for panelID in fallbackPanelIDs where seenPanelIDs.insert(panelID).inserted {
            if let adapter = tabAdaptersByPanelID[panelID],
               adapter.profileID == profileID {
                orderedAdapters.append(adapter)
            }
        }
        return orderedAdapters
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionActionPopupPresentation: NSObject, NSPopoverDelegate, WKUIDelegate {
    let id = UUID()
    private let popover = NSPopover()
    private let contentViewController = NSViewController()
    private let action: WKWebExtension.Action
    private let requestedContentSize: CGSize
    private let popupWebView: WKWebView
    private weak var previousUIDelegate: (any WKUIDelegate)?
    private weak var runtime: BrowserWebExtensionRuntime?
    private var outsideClickMonitor: Any?
    private var didClosePopup = false

    init(
        action: WKWebExtension.Action,
        popupWebView: WKWebView,
        requestedContentSize: CGSize,
        runtime: BrowserWebExtensionRuntime
    ) {
        self.action = action
        self.popupWebView = popupWebView
        self.requestedContentSize = requestedContentSize
        self.previousUIDelegate = popupWebView.uiDelegate
        self.runtime = runtime
        super.init()

        let containerView = NSView()
        popupWebView.removeFromSuperview()
        popupWebView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(popupWebView)
        NSLayoutConstraint.activate([
            popupWebView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            popupWebView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            popupWebView.topAnchor.constraint(equalTo: containerView.topAnchor),
            popupWebView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        contentViewController.view = containerView
        popover.contentViewController = contentViewController
        popover.delegate = self
        popover.behavior = .applicationDefined
        popover.animates = false
        popupWebView.uiDelegate = self
    }

    func show(
        relativeTo positioningRect: NSRect,
        of positioningView: NSView,
        preferredEdge: NSRectEdge
    ) {
        let visibleFrame = positioningView.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: CGSize(width: 800, height: 600))
        let requestedSize = requestedContentSize.width > 0 || requestedContentSize.height > 0
            ? requestedContentSize
            : popupWebView.frame.size
        let contentSize = browserWebExtensionActionPopupContentSize(
            requestedSize: requestedSize,
            visibleFrame: visibleFrame
        )
        contentViewController.preferredContentSize = contentSize
        contentViewController.view.setFrameSize(contentSize)
        popupWebView.setFrameSize(contentSize)
        popover.contentSize = contentSize
        let adjustedPositioningRect = browserWebExtensionActionPopupPositioningRect(
            positioningRect: positioningRect,
            positioningView: positioningView,
            popupWidth: contentSize.width
        )
        popover.show(
            relativeTo: adjustedPositioningRect,
            of: positioningView,
            preferredEdge: preferredEdge
        )
        installOutsideClickMonitor()
    }

    func close() {
        if popover.isShown {
            popover.close()
        } else {
            closeWebExtensionPopupIfNeeded()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        closeWebExtensionPopupIfNeeded()
        runtime?.actionPopupDidClose(self)
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  self.popover.isShown,
                  let popupWindow = self.contentViewController.view.window
            else {
                return event
            }
            if popupWindow.frame.contains(Self.screenLocation(for: event)) {
                return event
            }
            self.close()
            return event
        }
    }

    private static func screenLocation(for event: NSEvent) -> NSPoint {
        guard let eventWindow = event.window else {
            return NSEvent.mouseLocation
        }
        return eventWindow.convertPoint(toScreen: event.locationInWindow)
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func closeWebExtensionPopupIfNeeded() {
        guard !didClosePopup else { return }
        didClosePopup = true
        removeOutsideClickMonitor()
        restorePopupUIDelegate()
        action.closePopup()
    }

    private func restorePopupUIDelegate() {
        if popupWebView.uiDelegate === self {
            popupWebView.uiDelegate = previousUIDelegate
        }
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionAuxiliaryWindowAdapter: NSObject, WKWebExtensionWindow, NSWindowDelegate {
    let id = UUID()
    let createdAt = Date()
    let profileID: UUID
    let tabAdapter: BrowserWebExtensionAuxiliaryTabAdapter

    private weak var runtime: BrowserWebExtensionRuntime?
    private let panel: NSPanel
    private let webView: WKWebView
    private let windowType: WKWebExtension.WindowType
    private let isPrivateWindow: Bool
    private let uiDelegate = BrowserWebExtensionAuxiliaryUIDelegate()
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var didNotifyClose = false

    var isVisible: Bool {
        panel.isVisible
    }

    var isKeyWindow: Bool {
        panel.isKeyWindow
    }

    init(
        runtime: BrowserWebExtensionRuntime,
        profileID: UUID,
        configuration: WKWebExtension.WindowConfiguration,
        webViewConfiguration: WKWebViewConfiguration,
        customUserAgent: String,
        initialURL: URL?,
        openerPanel: BrowserPanel?
    ) {
        self.runtime = runtime
        self.profileID = profileID
        self.windowType = configuration.windowType
        self.isPrivateWindow = configuration.shouldBePrivate

        let screen = openerPanel?.webView.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let contentRect = browserWebExtensionAuxiliaryWindowContentRect(
            requestedFrame: configuration.frame,
            visibleFrame: visibleFrame,
            defaultSize: configuration.windowType == .popup
                ? CGSize(width: 420, height: 560)
                : CGSize(width: 900, height: 680),
            minSize: CGSize(width: 260, height: 180)
        )
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if configuration.windowType == .normal {
            styleMask.insert(.resizable)
        }

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-extension-window")
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 260, height: 180)
        panel.title = String(localized: "browser.popup.loadingTitle", defaultValue: "Loading\u{2026}")
        self.panel = panel

        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        webView.allowsBackForwardNavigationGestures = true
#if DEBUG
        webView.isInspectable = true
#endif
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        webView.customUserAgent = customUserAgent
        self.webView = webView
        self.tabAdapter = BrowserWebExtensionAuxiliaryTabAdapter(webView: webView, profileID: profileID)

        super.init()

        tabAdapter.windowAdapter = self
        uiDelegate.windowAdapter = self
        webView.uiDelegate = uiDelegate
        panel.delegate = self

        let urlLabel = NSTextField(labelWithString: "")
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(urlLabel)
        containerView.addSubview(webView)
        panel.contentView = containerView
        NSLayoutConstraint.activate([
            urlLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
            urlLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            urlLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            urlLabel.heightAnchor.constraint(equalToConstant: 16),

            webView.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 2),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self, weak webView] in
                guard let self else { return }
                let title = webView?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.panel.title = title?.isEmpty == false
                    ? title ?? ""
                    : String(localized: "browser.popup.loadingTitle", defaultValue: "Loading\u{2026}")
                self.runtime?.auxiliaryWindowDidChangeTabProperties(.title, tab: self.tabAdapter)
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self, weak webView] in
                guard let self else { return }
                urlLabel.stringValue = webView?.url?.absoluteString ?? ""
                self.runtime?.auxiliaryWindowDidChangeTabProperties(.URL, tab: self.tabAdapter)
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runtime?.auxiliaryWindowDidChangeTabProperties(.loading, tab: self.tabAdapter)
            }
        }

        if let initialURL {
            webView.load(URLRequest(url: initialURL))
        }
        if configuration.shouldBeFocused || configuration.windowType == .popup {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func closeWindow() {
        guard !didNotifyClose else { return }
        panel.close()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        runtime?.auxiliaryWindowDidFocus(self)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        titleObservation?.invalidate()
        urlObservation?.invalidate()
        loadingObservation?.invalidate()
        webView.stopLoading()
        webView.uiDelegate = nil
        runtime?.auxiliaryWindowDidClose(self)
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tabAdapter]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tabAdapter
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        windowType
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        if panel.styleMask.contains(.fullScreen) {
            return .fullscreen
        }
        if panel.isMiniaturized {
            return .minimized
        }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        switch state {
        case .minimized:
            panel.miniaturize(nil)
        case .fullscreen:
            if !panel.styleMask.contains(.fullScreen) {
                panel.toggleFullScreen(nil)
            }
        case .normal:
            if panel.isMiniaturized {
                panel.deminiaturize(nil)
            } else if panel.styleMask.contains(.fullScreen) {
                panel.toggleFullScreen(nil)
            }
        case .maximized:
            panel.zoom(nil)
        @unknown default:
            break
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        isPrivateWindow
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        panel.frame
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        panel.screen?.frame ?? .null
    }

    func setFrame(
        _ frame: CGRect,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        panel.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        closeWindow()
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionAuxiliaryUIDelegate: NSObject, WKUIDelegate {
    weak var windowAdapter: BrowserWebExtensionAuxiliaryWindowAdapter?

    func webViewDidClose(_ webView: WKWebView) {
        windowAdapter?.closeWindow()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           browserShouldOpenURLExternally(url) {
            Task { @MainActor in
                _ = try? await NSWorkspace.shared.open(
                    url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        }
        return nil
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionAuxiliaryTabAdapter: NSObject, WKWebExtensionTab {
    weak var windowAdapter: BrowserWebExtensionAuxiliaryWindowAdapter?
    private weak var webView: WKWebView?
    let profileID: UUID

    init(webView: WKWebView, profileID: UUID) {
        self.webView = webView
        self.profileID = profileID
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard webView?.configuration.webExtensionController === context.webExtensionController else {
            return nil
        }
        return webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        webView?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        webView?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        webView?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(webView?.isLoading ?? false)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(webView?.pageZoom ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        webView?.pageZoom = CGFloat(zoomFactor)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView?.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin {
            webView?.reloadFromOrigin()
        } else {
            webView?.reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        windowAdapter?.focus(for: context, completionHandler: completionHandler)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        windowAdapter?.isKeyWindow ?? false
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        windowAdapter?.closeWindow()
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var runtime: BrowserWebExtensionRuntime?
    let profileID: UUID

    init(profileID: UUID) {
        self.profileID = profileID
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        runtimeTabAdapters()
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        runtime?.activeTabAdapter(profileID: profileID) ?? runtimeTabAdapters().first
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = runtime?.activeTabAdapter(profileID: profileID)?.panel?.webView.window ?? NSApp.keyWindow else {
            return .normal
        }
        if window.styleMask.contains(.fullScreen) {
            return .fullscreen
        }
        if window.isMiniaturized {
            return .minimized
        }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        (runtime?.activeTabAdapter(profileID: profileID)?.panel?.webView.window ?? NSApp.keyWindow)?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (runtime?.activeTabAdapter(profileID: profileID)?.panel?.webView.window ?? NSApp.keyWindow)?.screen?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        runtime?.activeTabAdapter(profileID: profileID)?.panel?.focus()
        completionHandler(nil)
    }

    private func runtimeTabAdapters() -> [BrowserWebExtensionTabAdapter] {
        runtime?.tabAdapters(profileID: profileID) ?? []
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var panel: BrowserPanel?
    private weak var windowAdapter: BrowserWebExtensionWindowAdapter?
    let profileID: UUID

    init(panel: BrowserPanel, windowAdapter: BrowserWebExtensionWindowAdapter, profileID: UUID) {
        self.panel = panel
        self.windowAdapter = windowAdapter
        self.profileID = profileID
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard panel?.webView.configuration.webExtensionController === context.webExtensionController else {
            return nil
        }
        return panel?.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        panel?.displayTitle
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        panel.flatMap { BrowserPanel.remoteProxyDisplayURL(for: $0.webView.url) ?? $0.currentURL }
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        panel?.currentURL
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(panel?.isLoading ?? false)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        panel?.webView.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(panel?.currentPageZoomFactor() ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        _ = panel?.setPageZoomFactor(CGFloat(zoomFactor))
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel?.navigate(to: url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin {
            panel?.webView.reloadFromOrigin()
        } else {
            panel?.reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel?.focus()
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let panel else { return false }
        return AppDelegate.shared?.workspaceContainingPanel(
            panelId: panel.id,
            preferredWorkspaceId: panel.workspaceId
        )?.workspace.focusedPanelId == panel.id
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}
