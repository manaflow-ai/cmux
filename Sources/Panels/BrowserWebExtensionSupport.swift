import AppKit
import Foundation
import OSLog
import WebKit

nonisolated private let browserWebExtensionLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "BrowserExtensions"
)

struct BrowserWebExtensionInstalledSummary: Identifiable, Equatable, Sendable {
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

struct BrowserWebExtensionActionSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let badgeText: String
    let isEnabled: Bool
    let iconPNGData: Data?
}

private struct BrowserWebExtensionActivePopupState: Equatable {
    let presentationID: UUID
    let actionID: UUID
}

@available(macOS 15.4, *)
private struct BrowserWebExtensionAuxiliaryWebViewConfiguration {
    let runtimeKey: BrowserWebExtensionRuntimeKey
    let webViewConfiguration: WKWebViewConfiguration
}

@available(macOS 15.4, *)
private struct BrowserWebExtensionRuntimeKey: Hashable {
    enum DataStoreScope: Hashable {
        case defaultStore
        case persistent(UUID)
        case transient(UInt)
    }

    let profileID: UUID
    let dataStoreScope: DataStoreScope

    init(profileID: UUID, websiteDataStore: WKWebsiteDataStore) {
        self.profileID = profileID
        if let identifier = websiteDataStore.identifier {
            dataStoreScope = .persistent(identifier)
        } else if websiteDataStore === WKWebsiteDataStore.default() {
            dataStoreScope = .defaultStore
        } else {
            dataStoreScope = .transient(UInt(bitPattern: ObjectIdentifier(websiteDataStore)))
        }
    }

    var contextUniqueIdentifierDataStoreSuffix: String? {
        switch dataStoreScope {
        case .defaultStore:
            return nil
        case .persistent(let identifier):
            guard identifier != profileID else { return nil }
            return "store.\(identifier.uuidString.lowercased())"
        case .transient(let identity):
            return "store.transient.\(String(identity, radix: 16))"
        }
    }

    var isTransient: Bool {
        if case .transient = dataStoreScope {
            return true
        }
        return false
    }

    var controllerConfigurationIdentifier: UUID {
        switch dataStoreScope {
        case .defaultStore:
            return profileID
        case .persistent(let identifier):
            guard identifier != profileID else { return profileID }
            return Self.combinedControllerIdentifier(profileID: profileID, dataStoreID: identifier)
        case .transient:
            return profileID
        }
    }

    private static func combinedControllerIdentifier(profileID: UUID, dataStoreID: UUID) -> UUID {
        var bytes = profileID.uuid
        let storeBytes = dataStoreID.uuid
        bytes.0 ^= storeBytes.0 ^ 0x63
        bytes.1 ^= storeBytes.1 ^ 0x6d
        bytes.2 ^= storeBytes.2 ^ 0x75
        bytes.3 ^= storeBytes.3 ^ 0x78
        bytes.4 ^= storeBytes.4 ^ 0x65
        bytes.5 ^= storeBytes.5 ^ 0x78
        bytes.6 ^= storeBytes.6 ^ 0x74
        bytes.7 ^= storeBytes.7 ^ 0x6e
        bytes.8 ^= storeBytes.8 ^ 0x73
        bytes.9 ^= storeBytes.9 ^ 0x70
        bytes.10 ^= storeBytes.10 ^ 0x72
        bytes.11 ^= storeBytes.11 ^ 0x6f
        bytes.12 ^= storeBytes.12 ^ 0x66
        bytes.13 ^= storeBytes.13 ^ 0x69
        bytes.14 ^= storeBytes.14 ^ 0x6c
        bytes.15 ^= storeBytes.15 ^ 0x65
        return UUID(uuid: bytes)
    }
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

@available(macOS 15.4, *)
@MainActor
private func browserWebExtensionActionIconPNGData(
    for action: WKWebExtension.Action,
    pointSize: CGFloat = 18
) -> Data? {
    let targetSize = CGSize(width: pointSize, height: pointSize)
    guard let icon = action.icon(for: targetSize) else { return nil }

    let renderedIcon = NSImage(size: targetSize)
    renderedIcon.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(
        in: NSRect(origin: .zero, size: targetSize),
        from: NSRect(origin: .zero, size: icon.size),
        operation: .copy,
        fraction: 1
    )
    renderedIcon.unlockFocus()

    guard let tiffData = renderedIcon.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData)
    else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}

func browserWebExtensionActionPopupWindowLayout(
    anchorScreenRect: NSRect,
    contentSize: CGSize,
    allowedFrame: NSRect,
    arrowHeight: CGFloat = 10,
    margin: CGFloat = 12,
    minimumArrowInset: CGFloat = 16
) -> (frame: NSRect, arrowMidX: CGFloat) {
    let popupWidth = min(contentSize.width, max(1, allowedFrame.width - margin * 2))
    let popupHeight = min(contentSize.height + arrowHeight, max(1, allowedFrame.height - margin * 2))
    let minX = allowedFrame.minX + margin
    let maxX = max(minX, allowedFrame.maxX - margin - popupWidth)
    let desiredX = anchorScreenRect.midX - popupWidth / 2
    let x = min(max(desiredX, minX), maxX)
    let desiredY = anchorScreenRect.minY - popupHeight
    let y = max(allowedFrame.minY + margin, desiredY)
    let arrowMidX = min(
        max(anchorScreenRect.midX - x, minimumArrowInset),
        max(minimumArrowInset, popupWidth - minimumArrowInset)
    )
    return (
        NSRect(x: x, y: y, width: popupWidth, height: popupHeight),
        arrowMidX
    )
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

    private static let grantableAppExtensionPermissions: Set<String> = [
        "activeTab",
        "alarms",
        "bookmarks",
        "clipboardRead",
        "clipboardWrite",
        "contextMenus",
        "cookies",
        "declarativeNetRequest",
        "declarativeNetRequestFeedback",
        "declarativeNetRequestWithHostAccess",
        "downloads",
        "favicon",
        "history",
        "idle",
        "management",
        "menus",
        "nativeMessaging",
        "notifications",
        "offscreen",
        "privacy",
        "scripting",
        "storage",
        "tabs",
        "unlimitedStorage",
        "webNavigation",
        "webRequest",
        "webRequestAuthProvider",
        "webRequestBlocking",
    ]

    func isPermissionGrantable(
        _ rawPermission: String,
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> Bool {
        sourceKind == .appExtensionBundle &&
            Self.grantableAppExtensionPermissions.contains(rawPermission)
    }

    func grantablePermissionNames(
        from rawPermissions: [String],
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> [String] {
        guard sourceKind == .appExtensionBundle else { return [] }
        return Array(Set(rawPermissions).intersection(Self.grantableAppExtensionPermissions)).sorted()
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

struct BrowserWebExtensionInstallResult: Equatable, Sendable {
    let summary: BrowserWebExtensionInstalledSummary
    let parseErrors: [String]
}

struct BrowserWebExtensionProfileState: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var grantedPermissions: [String]
    var deniedPermissions: [String]
    var grantedPermissionURLs: [String]
    var deniedPermissionURLs: [String]
    var grantedPermissionMatchPatterns: [String]
    var deniedPermissionMatchPatterns: [String]
    var lastError: String?

    init(
        isEnabled: Bool,
        grantedPermissions: [String],
        grantedPermissionMatchPatterns: [String],
        deniedPermissions: [String] = [],
        grantedPermissionURLs: [String] = [],
        deniedPermissionURLs: [String] = [],
        deniedPermissionMatchPatterns: [String] = [],
        lastError: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.grantedPermissions = grantedPermissions
        self.deniedPermissions = deniedPermissions
        self.grantedPermissionURLs = grantedPermissionURLs
        self.deniedPermissionURLs = deniedPermissionURLs
        self.grantedPermissionMatchPatterns = grantedPermissionMatchPatterns
        self.deniedPermissionMatchPatterns = deniedPermissionMatchPatterns
        self.lastError = lastError
    }

    func sanitized(sourceKind: BrowserWebExtensionInstallRecord.SourceKind) -> BrowserWebExtensionProfileState {
        let grantedPermissions = Set(browserWebExtensionHostGrantablePermissionNames(
            from: grantedPermissions,
            sourceKind: sourceKind
        ))
        let deniedPermissions = Set(browserWebExtensionHostGrantablePermissionNames(
            from: deniedPermissions,
            sourceKind: sourceKind
        )).subtracting(grantedPermissions)
        let grantedPermissionURLs = Set(grantedPermissionURLs)
        let deniedPermissionURLs = Set(deniedPermissionURLs).subtracting(grantedPermissionURLs)
        let grantedPermissionMatchPatterns = Set(grantedPermissionMatchPatterns)
        let deniedPermissionMatchPatterns = Set(deniedPermissionMatchPatterns)
            .subtracting(grantedPermissionMatchPatterns)

        return BrowserWebExtensionProfileState(
            isEnabled: isEnabled,
            grantedPermissions: grantedPermissions.sorted(),
            grantedPermissionMatchPatterns: grantedPermissionMatchPatterns.sorted(),
            deniedPermissions: deniedPermissions.sorted(),
            grantedPermissionURLs: grantedPermissionURLs.sorted(),
            deniedPermissionURLs: deniedPermissionURLs.sorted(),
            deniedPermissionMatchPatterns: deniedPermissionMatchPatterns.sorted(),
            lastError: lastError
        )
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case grantedPermissions
        case deniedPermissions
        case grantedPermissionURLs
        case deniedPermissionURLs
        case grantedPermissionMatchPatterns
        case deniedPermissionMatchPatterns
        case lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        grantedPermissions = try container.decode([String].self, forKey: .grantedPermissions)
        deniedPermissions = try container.decodeIfPresent([String].self, forKey: .deniedPermissions) ?? []
        grantedPermissionURLs = try container.decodeIfPresent([String].self, forKey: .grantedPermissionURLs) ?? []
        deniedPermissionURLs = try container.decodeIfPresent([String].self, forKey: .deniedPermissionURLs) ?? []
        grantedPermissionMatchPatterns = try container.decode(
            [String].self,
            forKey: .grantedPermissionMatchPatterns
        )
        deniedPermissionMatchPatterns = try container.decodeIfPresent(
            [String].self,
            forKey: .deniedPermissionMatchPatterns
        ) ?? []
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

struct BrowserWebExtensionInstallRecord: Codable, Equatable, Identifiable, Sendable {
    enum SourceKind: String, Codable, Sendable {
        case appExtensionBundle
    }

    let id: UUID
    var displayName: String
    var displayVersion: String?
    var sourceKind: SourceKind
    var sourcePath: String
    var isEnabled: Bool
    var grantedPermissions: [String]
    var deniedPermissions: [String]
    var grantedPermissionURLs: [String]
    var deniedPermissionURLs: [String]
    var grantedPermissionMatchPatterns: [String]
    var deniedPermissionMatchPatterns: [String]
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
        deniedPermissions: [String] = [],
        grantedPermissionURLs: [String] = [],
        deniedPermissionURLs: [String] = [],
        deniedPermissionMatchPatterns: [String] = [],
        profileStates: [String: BrowserWebExtensionProfileState] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.displayVersion = displayVersion
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.isEnabled = isEnabled
        self.grantedPermissions = grantedPermissions
        self.deniedPermissions = deniedPermissions
        self.grantedPermissionURLs = grantedPermissionURLs
        self.deniedPermissionURLs = deniedPermissionURLs
        self.grantedPermissionMatchPatterns = grantedPermissionMatchPatterns
        self.deniedPermissionMatchPatterns = deniedPermissionMatchPatterns
        self.profileStates = profileStates
    }

    var defaultProfileState: BrowserWebExtensionProfileState {
        BrowserWebExtensionProfileState(
            isEnabled: isEnabled,
            grantedPermissions: grantedPermissions,
            grantedPermissionMatchPatterns: grantedPermissionMatchPatterns,
            deniedPermissions: deniedPermissions,
            grantedPermissionURLs: grantedPermissionURLs,
            deniedPermissionURLs: deniedPermissionURLs,
            deniedPermissionMatchPatterns: deniedPermissionMatchPatterns,
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
        case deniedPermissions
        case grantedPermissionURLs
        case deniedPermissionURLs
        case grantedPermissionMatchPatterns
        case deniedPermissionMatchPatterns
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
        deniedPermissions = try container.decodeIfPresent([String].self, forKey: .deniedPermissions) ?? []
        grantedPermissionURLs = try container.decodeIfPresent([String].self, forKey: .grantedPermissionURLs) ?? []
        deniedPermissionURLs = try container.decodeIfPresent([String].self, forKey: .deniedPermissionURLs) ?? []
        grantedPermissionMatchPatterns = try container.decode([String].self, forKey: .grantedPermissionMatchPatterns)
        deniedPermissionMatchPatterns = try container.decodeIfPresent(
            [String].self,
            forKey: .deniedPermissionMatchPatterns
        ) ?? []
        profileStates = try container.decodeIfPresent(
            [String: BrowserWebExtensionProfileState].self,
            forKey: .profileStates
        ) ?? [:]
    }
}

private struct BrowserWebExtensionPersistedInstallRecord: Decodable {
    let id: UUID
    let displayName: String
    let displayVersion: String?
    let sourceKind: String
    let sourcePath: String
    let isEnabled: Bool
    let grantedPermissions: [String]
    let deniedPermissions: [String]
    let grantedPermissionURLs: [String]
    let deniedPermissionURLs: [String]
    let grantedPermissionMatchPatterns: [String]
    let deniedPermissionMatchPatterns: [String]
    let profileStates: [String: BrowserWebExtensionProfileState]

    func installRecord() -> BrowserWebExtensionInstallRecord? {
        guard let sourceKind = BrowserWebExtensionInstallRecord.SourceKind(rawValue: sourceKind) else {
            return nil
        }
        return BrowserWebExtensionInstallRecord(
            id: id,
            displayName: displayName,
            displayVersion: displayVersion,
            sourceKind: sourceKind,
            sourcePath: sourcePath,
            isEnabled: isEnabled,
            grantedPermissions: grantedPermissions,
            grantedPermissionMatchPatterns: grantedPermissionMatchPatterns,
            deniedPermissions: deniedPermissions,
            grantedPermissionURLs: grantedPermissionURLs,
            deniedPermissionURLs: deniedPermissionURLs,
            deniedPermissionMatchPatterns: deniedPermissionMatchPatterns,
            profileStates: profileStates
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case displayVersion
        case sourceKind
        case sourcePath
        case isEnabled
        case grantedPermissions
        case deniedPermissions
        case grantedPermissionURLs
        case deniedPermissionURLs
        case grantedPermissionMatchPatterns
        case deniedPermissionMatchPatterns
        case profileStates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        displayVersion = try container.decodeIfPresent(String.self, forKey: .displayVersion)
        sourceKind = try container.decode(String.self, forKey: .sourceKind)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        grantedPermissions = try container.decode([String].self, forKey: .grantedPermissions)
        deniedPermissions = try container.decodeIfPresent([String].self, forKey: .deniedPermissions) ?? []
        grantedPermissionURLs = try container.decodeIfPresent([String].self, forKey: .grantedPermissionURLs) ?? []
        deniedPermissionURLs = try container.decodeIfPresent([String].self, forKey: .deniedPermissionURLs) ?? []
        grantedPermissionMatchPatterns = try container.decode([String].self, forKey: .grantedPermissionMatchPatterns)
        deniedPermissionMatchPatterns = try container.decodeIfPresent(
            [String].self,
            forKey: .deniedPermissionMatchPatterns
        ) ?? []
        profileStates = try container.decodeIfPresent(
            [String: BrowserWebExtensionProfileState].self,
            forKey: .profileStates
        ) ?? [:]
    }
}

struct BrowserWebExtensionInstallSource: Equatable, Sendable {
    let kind: BrowserWebExtensionInstallRecord.SourceKind
    let url: URL
}

func browserWebExtensionSourceDescription(
    for sourceKind: BrowserWebExtensionInstallRecord.SourceKind
) -> String {
    switch sourceKind {
    case .appExtensionBundle:
        return String(localized: "browser.extensions.summary.appExtension", defaultValue: "Safari app extension")
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
    profileID: UUID,
    dataStoreSuffix: String? = nil
) -> String? {
    switch record.sourceKind {
    case .appExtensionBundle:
        let bundleIdentifier = Bundle(url: URL(fileURLWithPath: record.sourcePath))?
            .bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        let profileIdentifier = "\(bundleIdentifier).cmux-profile.\(profileID.uuidString.lowercased())"
        guard let dataStoreSuffix, !dataStoreSuffix.isEmpty else {
            return profileIdentifier
        }
        return "\(profileIdentifier).\(dataStoreSuffix)"
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
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return String(localized: "browser.extensions.error.unsupportedOS", defaultValue: "Browser extensions require macOS 15.4 or later.")
        case .cancelled:
            return String(localized: "browser.extensions.error.cancelled", defaultValue: "Extension installation was cancelled.")
        case .noManifest(let url):
            return String(
                format: String(localized: "browser.extensions.error.noManifest", defaultValue: "No manifest.json was found in %@."),
                url.lastPathComponent
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
        case .loadFailed:
            return String(localized: "browser.extensions.error.loadFailed", defaultValue: "The extension could not be loaded. Check that the app contains a valid Safari Web Extension.")
        case .persistFailed:
            return String(localized: "browser.extensions.error.persistFailed", defaultValue: "The extension registry could not be saved.")
        case .invalidRequest(let message):
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
    private var unsupportedPersistedRecordObjects: [[String: Any]] = []

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
            records = []
            unsupportedPersistedRecordObjects = []
            return
        }

        do {
            let data = try Data(contentsOf: registryURL)
            let rawObjects = Self.registryObjects(from: data)
            let persisted = try JSONDecoder().decode([BrowserWebExtensionPersistedInstallRecord].self, from: data)
            unsupportedPersistedRecordObjects = []
            let decoded: [BrowserWebExtensionInstallRecord] = persisted.enumerated().compactMap { index, persistedRecord in
                guard let record = persistedRecord.installRecord() else {
                    if rawObjects.indices.contains(index) {
                        unsupportedPersistedRecordObjects.append(rawObjects[index])
                    }
                    return nil
                }
                return record
            }
            records = decoded.compactMap(sanitizedRecord)
            if records.count != persisted.count || records != decoded {
                try? persist()
            }
        } catch {
            records = []
            unsupportedPersistedRecordObjects = []
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
        let existingRecord = existingRecord(for: source)
        let recordID = existingRecord?.id ?? UUID()
        let previousRecords = records
        let sanitizedPermissions = browserWebExtensionHostGrantablePermissionNames(
            from: grantedPermissions,
            sourceKind: source.kind
        ).sorted()
        let sanitizedMatchPatterns = grantedPermissionMatchPatterns.sorted()
        let deniedPermissions = existingRecord?.deniedPermissions ?? []
        let grantedPermissionURLs = existingRecord?.grantedPermissionURLs ?? []
        let deniedPermissionURLs = existingRecord?.deniedPermissionURLs ?? []
        let deniedPermissionMatchPatterns = existingRecord?.deniedPermissionMatchPatterns ?? []
        let profileStates = Dictionary(
            uniqueKeysWithValues: (existingRecord?.profileStates ?? [:]).map { key, state in
                (
                    key,
                    BrowserWebExtensionProfileState(
                        isEnabled: state.isEnabled,
                        grantedPermissions: sanitizedPermissions,
                        grantedPermissionMatchPatterns: sanitizedMatchPatterns,
                        deniedPermissions: state.deniedPermissions,
                        grantedPermissionURLs: state.grantedPermissionURLs,
                        deniedPermissionURLs: state.deniedPermissionURLs,
                        deniedPermissionMatchPatterns: state.deniedPermissionMatchPatterns,
                        lastError: state.lastError
                    ).sanitized(sourceKind: source.kind)
                )
            }
        )

        let record = BrowserWebExtensionInstallRecord(
            id: recordID,
            displayName: displayName,
            displayVersion: displayVersion,
            sourceKind: source.kind,
            sourcePath: source.url.path,
            isEnabled: existingRecord?.isEnabled ?? true,
            grantedPermissions: sanitizedPermissions,
            grantedPermissionMatchPatterns: sanitizedMatchPatterns,
            deniedPermissions: deniedPermissions,
            grantedPermissionURLs: grantedPermissionURLs,
            deniedPermissionURLs: deniedPermissionURLs,
            deniedPermissionMatchPatterns: deniedPermissionMatchPatterns,
            profileStates: profileStates
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

    func recordRuntimePermissionDecision(
        granted: Bool,
        permissions: [String] = [],
        permissionURLs: [String] = [],
        permissionMatchPatterns: [String] = [],
        for recordID: UUID,
        profileID: UUID
    ) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var nextRecords = records
        var state = nextRecords[index].profileState(for: profileID)
        let sourceKind = nextRecords[index].sourceKind
        let grantablePermissions = browserWebExtensionHostGrantablePermissionNames(
            from: permissions,
            sourceKind: sourceKind
        )

        if granted {
            state.grantedPermissions = Self.union(state.grantedPermissions, grantablePermissions)
            state.deniedPermissions = Self.subtract(state.deniedPermissions, grantablePermissions)
            state.grantedPermissionURLs = Self.union(state.grantedPermissionURLs, permissionURLs)
            state.deniedPermissionURLs = Self.subtract(state.deniedPermissionURLs, permissionURLs)
            state.grantedPermissionMatchPatterns = Self.union(
                state.grantedPermissionMatchPatterns,
                permissionMatchPatterns
            )
            state.deniedPermissionMatchPatterns = Self.subtract(
                state.deniedPermissionMatchPatterns,
                permissionMatchPatterns
            )
        } else {
            state.deniedPermissions = Self.union(state.deniedPermissions, grantablePermissions)
            state.grantedPermissions = Self.subtract(state.grantedPermissions, grantablePermissions)
            state.deniedPermissionURLs = Self.union(state.deniedPermissionURLs, permissionURLs)
            state.grantedPermissionURLs = Self.subtract(state.grantedPermissionURLs, permissionURLs)
            state.deniedPermissionMatchPatterns = Self.union(
                state.deniedPermissionMatchPatterns,
                permissionMatchPatterns
            )
            state.grantedPermissionMatchPatterns = Self.subtract(
                state.grantedPermissionMatchPatterns,
                permissionMatchPatterns
            )
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

    static func discoverSource(
        from url: URL,
        developerModeEnabled: Bool = BrowserExtensionDeveloperModeSettings.isEnabled(),
        fileManager: FileManager = .default
    ) throws -> BrowserWebExtensionInstallSource {
        let resolvedURL = url.standardizedFileURL
        let pathExtension = resolvedURL.pathExtension.lowercased()

        if pathExtension == "app" {
            guard let appExtensionURL = firstWebExtensionAppExtension(in: resolvedURL, fileManager: fileManager) else {
                throw BrowserWebExtensionInstallError.noWebExtensionInApp(resolvedURL)
            }
            return BrowserWebExtensionInstallSource(kind: .appExtensionBundle, url: appExtensionURL)
        }

        if pathExtension == "appex" {
            guard developerModeEnabled else {
                throw BrowserWebExtensionInstallError.developerModeRequired(resolvedURL)
            }
            switch appExtensionValidationResult(for: resolvedURL, fileManager: fileManager) {
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

    func discoverSource(
        from url: URL,
        developerModeEnabled: Bool = BrowserExtensionDeveloperModeSettings.isEnabled()
    ) throws -> BrowserWebExtensionInstallSource {
        try Self.discoverSource(
            from: url,
            developerModeEnabled: developerModeEnabled,
            fileManager: fileManager
        )
    }

    private func existingRecord(for source: BrowserWebExtensionInstallSource) -> BrowserWebExtensionInstallRecord? {
        guard source.kind == .appExtensionBundle else { return nil }
        return records.first { record in
            record.sourceKind == source.kind && URL(fileURLWithPath: record.sourcePath).standardizedFileURL == source.url.standardizedFileURL
        }
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
            let data = try Self.registryData(
                supportedRecords: recordsToPersist,
                unsupportedRecordObjects: unsupportedPersistedRecordObjects
            )
            try data.write(to: registryURL, options: .atomic)
        } catch {
            browserWebExtensionLogger.error(
                "Failed to save extension registry: \(error.localizedDescription, privacy: .private)"
            )
            throw BrowserWebExtensionInstallError.persistFailed(error.localizedDescription)
        }
    }

    private func quarantineCorruptRegistry(after error: Error) {
        browserWebExtensionLogger.error(
            "Failed to reload extension registry: \(error.localizedDescription, privacy: .private)"
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = registryURL.deletingLastPathComponent()
            .appendingPathComponent("\(registryURL.deletingPathExtension().lastPathComponent).\(timestamp).corrupt.json")
        do {
            try fileManager.moveItem(at: registryURL, to: quarantineURL)
        } catch {
            browserWebExtensionLogger.error(
                "Failed to quarantine extension registry: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func registryObjects(from data: Data) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private static func registryData(
        supportedRecords: [BrowserWebExtensionInstallRecord],
        unsupportedRecordObjects: [[String: Any]]
    ) throws -> Data {
        let supportedData = try JSONEncoder.cmuxBrowserExtensions.encode(supportedRecords)
        let supportedObjects = registryObjects(from: supportedData)
        return try JSONSerialization.data(
            withJSONObject: supportedObjects + unsupportedRecordObjects,
            options: [.prettyPrinted, .sortedKeys]
        )
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
        record.deniedPermissions = browserWebExtensionHostGrantablePermissionNames(
            from: record.deniedPermissions,
            sourceKind: record.sourceKind
        ).filter { !record.grantedPermissions.contains($0) }.sorted()
        record.grantedPermissionURLs = Array(Set(record.grantedPermissionURLs)).sorted()
        record.deniedPermissionURLs = Array(Set(record.deniedPermissionURLs))
            .filter { !record.grantedPermissionURLs.contains($0) }
            .sorted()
        record.grantedPermissionMatchPatterns = record.grantedPermissionMatchPatterns.sorted()
        record.deniedPermissionMatchPatterns = Array(Set(record.deniedPermissionMatchPatterns))
            .filter { !record.grantedPermissionMatchPatterns.contains($0) }
            .sorted()
        record.profileStates = Dictionary(
            uniqueKeysWithValues: record.profileStates.map { key, state in
                (key, state.sanitized(sourceKind: record.sourceKind))
            }
        )
        return record
    }

    private static func union(_ lhs: [String], _ rhs: [String]) -> [String] {
        Array(Set(lhs).union(rhs)).sorted()
    }

    private static func subtract(_ lhs: [String], _ rhs: [String]) -> [String] {
        Array(Set(lhs).subtracting(rhs)).sorted()
    }

    private static func firstWebExtensionAppExtension(
        in appURL: URL,
        fileManager: FileManager
    ) -> URL? {
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
            .filter { appExtensionValidationResult(for: $0, fileManager: fileManager) == .valid }
        guard validAppExtensions.count == 1 else {
            return nil
        }
        return validAppExtensions[0]
    }

    private static func appExtensionValidationResult(
        for appexURL: URL,
        fileManager: FileManager
    ) -> AppExtensionValidationResult {
        guard appExtensionHasManifest(appexURL, fileManager: fileManager) else {
            return .missingManifest
        }

        guard appExtensionInfoPlistExists(appexURL, fileManager: fileManager) else {
            return .missingInfoPlist
        }

        guard appExtensionPointIdentifier(in: appexURL, fileManager: fileManager) == Self.safariWebExtensionPointIdentifier else {
            return .notSafariWebExtension
        }
        return .valid
    }

    private static func appExtensionHasManifest(
        _ appexURL: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(
            atPath: appexURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("manifest.json", isDirectory: false)
                .path
        )
    }

    private static func appExtensionInfoPlistExists(
        _ appexURL: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(atPath: appExtensionInfoPlistURL(for: appexURL).path)
    }

    private static func appExtensionPointIdentifier(
        in appexURL: URL,
        fileManager: FileManager
    ) -> String? {
        guard let data = fileManager.contents(atPath: appExtensionInfoPlistURL(for: appexURL).path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let extensionDictionary = dictionary["NSExtension"] as? [String: Any] else {
            return nil
        }
        return extensionDictionary["NSExtensionPointIdentifier"] as? String
    }

    private static func appExtensionInfoPlistURL(for appexURL: URL) -> URL {
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

    static func activeActionPopupSnapshot(for panel: BrowserPanel) -> BrowserWebExtensionActionSnapshot? {
        guard #available(macOS 15.4, *) else { return nil }
        return BrowserWebExtensionRuntime.shared.activeActionPopupSnapshot(for: panel)
    }

    static func performAction(_ actionID: UUID, for panel: BrowserPanel) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.performAction(actionID, for: panel)
    }

    static func setActionPopupAnchorView(_ view: NSView?, forPanelID panelID: UUID) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.setActionPopupAnchorView(view, forPanelID: panelID)
    }

    static func noteActionPopupAnchorGeometryChanged(_ view: NSView, forPanelID panelID: UUID) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.noteActionPopupAnchorGeometryChanged(view, forPanelID: panelID)
    }

    static func installExtension(
        from url: URL,
        profileID: UUID? = nil
    ) async throws -> BrowserWebExtensionInstallResult {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionInstallError.unsupportedOS
        }
        let resolvedProfileID = profileID ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return try await BrowserWebExtensionRuntime.shared.installExtension(
            from: url,
            profileID: resolvedProfileID
        )
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

    static func notePanelFocusChanged(panel: BrowserPanel, isFocused: Bool) {
        guard #available(macOS 15.4, *), isFocused else { return }
        BrowserWebExtensionRuntime.shared.notePanelDidBecomeActive(panel: panel)
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
    private var controllersByRuntimeKey: [BrowserWebExtensionRuntimeKey: WKWebExtensionController] = [:]
    private var contextsByRuntimeKey: [BrowserWebExtensionRuntimeKey: [UUID: WKWebExtensionContext]] = [:]
    private var websiteDataStoresByRuntimeKey: [BrowserWebExtensionRuntimeKey: WKWebsiteDataStore] = [:]
    private var tabAdaptersByPanelID: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var auxiliaryWindowAdaptersByID: [UUID: BrowserWebExtensionAuxiliaryWindowAdapter] = [:]
    private var actionPopupPresentationsByID: [UUID: BrowserWebExtensionActionPopupPresentation] = [:]
    private var actionPopupAnchorViewsByPanelID: [UUID: BrowserWebExtensionWeakView] = [:]
    private var actionPopupAnchorScreenRectsByPanelID: [UUID: NSRect] = [:]
    private var activeActionPopupByPanelID: [UUID: BrowserWebExtensionActivePopupState] = [:]
    private var windowAdaptersByRuntimeKey: [BrowserWebExtensionRuntimeKey: BrowserWebExtensionWindowAdapter] = [:]
    private var activeTabsByRuntimeKey: [BrowserWebExtensionRuntimeKey: any WKWebExtensionTab] = [:]
    private var runtimePermissionPromptTasks: [UUID: Task<Void, Never>] = [:]
    private var runtimePermissionPromptDenyHandlers: [UUID: () -> Void] = [:]
    private var runtimePermissionPromptWindows: [UUID: NSWindow] = [:]
    private var backgroundLoadTasksByRuntimeKey: [BrowserWebExtensionRuntimeKey: [UUID: Task<Void, Never>]] = [:]
    private var loadedRuntimeKeys: Set<BrowserWebExtensionRuntimeKey> = []

    override init() {
        super.init()
    }

    func configure(
        _ configuration: WKWebViewConfiguration,
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) {
        let key = runtimeKey(profileID: profileID, websiteDataStore: websiteDataStore)
        let controller = ensureController(
            runtimeKey: key,
            defaultWebsiteDataStore: websiteDataStore
        )
        configuration.webExtensionController = controller
    }

    func register(panel: BrowserPanel) {
        let key = runtimeKey(for: panel)
        let controller = ensureController(
            runtimeKey: key,
            defaultWebsiteDataStore: panel.websiteDataStore
        )
        let windowAdapter = ensureWindowAdapter(runtimeKey: key)
        let existingAdapter = tabAdaptersByPanelID[panel.id]
        if let existingAdapter, existingAdapter.runtimeKey != key {
            controllersByRuntimeKey[existingAdapter.runtimeKey]?.didCloseTab(existingAdapter, windowIsClosing: false)
            if isSameTab(activeTabsByRuntimeKey[existingAdapter.runtimeKey], existingAdapter) {
                activeTabsByRuntimeKey[existingAdapter.runtimeKey] = nil
            }
            tabAdaptersByPanelID[panel.id] = nil
        }
        let adapter = tabAdaptersByPanelID[panel.id]
            ?? BrowserWebExtensionTabAdapter(
                panel: panel,
                windowAdapter: windowAdapter,
                runtimeKey: key
            )
        adapter.panel = panel
        tabAdaptersByPanelID[panel.id] = adapter
        if existingAdapter == nil || existingAdapter?.runtimeKey != key {
            controller.didOpenTab(adapter)
        }
        if shouldNotifyWindowFocus(for: panel) {
            noteActiveTab(adapter, runtimeKey: key, focusedWindow: windowAdapter)
        }
        controller.didChangeTabProperties(WKWebExtension.TabChangedProperties([.title, .URL, .loading]), for: adapter)
        Task { @MainActor [weak self, websiteDataStore = panel.websiteDataStore] in
            await self?.loadInstalledRecordsIfNeeded(runtimeKey: key, websiteDataStore: websiteDataStore)
        }
        postDidChange()
    }

    func unregister(panelID: UUID) {
        guard let adapter = tabAdaptersByPanelID.removeValue(forKey: panelID) else { return }
        closeActionPopup(forPanelID: panelID)
        actionPopupAnchorViewsByPanelID.removeValue(forKey: panelID)
        actionPopupAnchorScreenRectsByPanelID.removeValue(forKey: panelID)
        controllersByRuntimeKey[adapter.runtimeKey]?.didCloseTab(adapter, windowIsClosing: false)
        if isSameTab(activeTabsByRuntimeKey[adapter.runtimeKey], adapter) {
            activeTabsByRuntimeKey[adapter.runtimeKey] = nil
        }
        postDidChange()
    }

    func installedExtensionSummaries(profileID: UUID) -> [BrowserWebExtensionInstalledSummary] {
        let loadedRecordIDs = contextsByRuntimeKey.reduce(into: Set<UUID>()) { result, element in
            guard element.key.profileID == profileID else { return }
            result.formUnion(element.value.keys)
        }
        return store.summaries(
            profileID: profileID,
            loadedRecordIDs: loadedRecordIDs
        )
    }

    func actionSnapshots(for panel: BrowserPanel) -> [BrowserWebExtensionActionSnapshot] {
        guard let tab = tabAdaptersByPanelID[panel.id] else { return [] }
        return contextsByRuntimeKey[tab.runtimeKey, default: [:]].compactMap { recordID, context in
            actionSnapshot(recordID: recordID, context: context, tab: tab)
        }
        .sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    func activeActionPopupSnapshot(for panel: BrowserPanel) -> BrowserWebExtensionActionSnapshot? {
        guard let activePopup = activeActionPopupByPanelID[panel.id],
              let tab = tabAdaptersByPanelID[panel.id],
              let context = contextsByRuntimeKey[tab.runtimeKey]?[activePopup.actionID]
        else {
            return nil
        }
        return actionSnapshot(recordID: activePopup.actionID, context: context, tab: tab)
    }

    func performAction(_ actionID: UUID, for panel: BrowserPanel) {
        guard let runtimeKey = tabAdaptersByPanelID[panel.id]?.runtimeKey,
              let context = contextsByRuntimeKey[runtimeKey]?[actionID] else {
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
        updateActionPopupAnchorScreenRect(view, forPanelID: panelID)
    }

    func noteActionPopupAnchorGeometryChanged(_ view: NSView, forPanelID panelID: UUID) {
        if actionPopupAnchorViewsByPanelID[panelID]?.view == nil {
            actionPopupAnchorViewsByPanelID[panelID] = BrowserWebExtensionWeakView(view)
        }
        updateActionPopupAnchorScreenRect(view, forPanelID: panelID)
    }

    private func updateActionPopupAnchorScreenRect(_ view: NSView, forPanelID panelID: UUID) {
        guard let window = view.window,
              !view.bounds.isEmpty
        else {
            return
        }
        let rectInWindow = view.convert(view.bounds, to: nil)
        actionPopupAnchorScreenRectsByPanelID[panelID] = window.convertToScreen(rectInWindow)
    }

    func notePanelPropertiesChanged(panel: BrowserPanel) {
        guard let tab = tabAdaptersByPanelID[panel.id] else { return }
        controllersByRuntimeKey[tab.runtimeKey]?.didChangeTabProperties([.title, .URL, .loading], for: tab)
        postDidChange()
    }

    func notePanelDidBecomeActive(panel: BrowserPanel) {
        guard let tab = tabAdaptersByPanelID[panel.id] else { return }
        let window = ensureWindowAdapter(runtimeKey: tab.runtimeKey)
        noteActiveTab(tab, runtimeKey: tab.runtimeKey, focusedWindow: window)
    }

    func installExtension(
        from url: URL,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstallResult {
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
            browserWebExtensionLogger.error(
                "Failed to load extension during install: \(firstError.localizedDescription, privacy: .private)"
            )
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
        try await load(record: record, profileID: profileID)
        postDidChange()
        let loadedRecordIDs = contextsByRuntimeKey.reduce(into: Set<UUID>()) { result, element in
            guard element.key.profileID == profileID else { return }
            result.formUnion(element.value.keys)
        }
        let summary = store.summaries(
            profileID: profileID,
            loadedRecordIDs: loadedRecordIDs
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
                grantedPermissions: record.profileState(for: profileID).grantedPermissions,
                grantedPermissionMatchPatterns: record.profileState(for: profileID).grantedPermissionMatchPatterns,
                isEnabled: record.profileState(for: profileID).isEnabled,
                isLoaded: loadedRecordIDs.contains(record.id),
                lastError: record.profileState(for: profileID).lastError
            )
        return BrowserWebExtensionInstallResult(summary: summary, parseErrors: parseErrors)
    }

    func reloadInstalledExtensions() async {
        cancelRuntimePermissionPrompts()
        closeAllActionPopups()
        closeAllAuxiliaryWindows()
        cancelAllBackgroundLoadTasks()
        for (runtimeKey, contextsByRecordID) in contextsByRuntimeKey {
            guard let controller = controllersByRuntimeKey[runtimeKey] else { continue }
            for context in contextsByRecordID.values {
                try? controller.unload(context)
            }
        }
        contextsByRuntimeKey.removeAll()
        loadedRuntimeKeys.removeAll()
        store.reload()
        for (runtimeKey, dataStore) in websiteDataStoresByRuntimeKey {
            await loadInstalledRecordsIfNeeded(runtimeKey: runtimeKey, websiteDataStore: dataStore)
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
            closeActionPopups(recordID: id, profileID: profileID)
            closeAuxiliaryWindows(recordID: id, profileID: profileID)
            unload(recordID: id, profileID: profileID)
        }
        postDidChange()
        return try summary(for: id, profileID: profileID)
    }

    func removeExtension(id: UUID) throws {
        cancelRuntimePermissionPrompts()
        closeAllActionPopups()
        closeAuxiliaryWindows(recordID: id)
        for runtimeKey in controllersByRuntimeKey.keys {
            unload(recordID: id, runtimeKey: runtimeKey)
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
        runtimeKey: BrowserWebExtensionRuntimeKey,
        defaultWebsiteDataStore: WKWebsiteDataStore
    ) -> WKWebExtensionController {
        websiteDataStoresByRuntimeKey[runtimeKey] = defaultWebsiteDataStore
        if let controller = controllersByRuntimeKey[runtimeKey] {
            return controller
        }

        let baseConfiguration = WKWebViewConfiguration()
        browserWebExtensionConfigureBaseWebViewConfiguration(
            baseConfiguration,
            defaultWebsiteDataStore: defaultWebsiteDataStore
        )

        let configuration = runtimeKey.isTransient
            ? WKWebExtensionController.Configuration.nonPersistent()
            : WKWebExtensionController.Configuration(identifier: runtimeKey.controllerConfigurationIdentifier)
        configuration.webViewConfiguration = baseConfiguration
        configuration.defaultWebsiteDataStore = defaultWebsiteDataStore

        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        controllersByRuntimeKey[runtimeKey] = controller

        Task { @MainActor [weak self] in
            await self?.loadInstalledRecordsIfNeeded(runtimeKey: runtimeKey, websiteDataStore: defaultWebsiteDataStore)
        }

        return controller
    }

    private func ensureWindowAdapter(runtimeKey: BrowserWebExtensionRuntimeKey) -> BrowserWebExtensionWindowAdapter {
        if let adapter = windowAdaptersByRuntimeKey[runtimeKey] {
            return adapter
        }
        let adapter = BrowserWebExtensionWindowAdapter(runtimeKey: runtimeKey)
        adapter.runtime = self
        windowAdaptersByRuntimeKey[runtimeKey] = adapter
        return adapter
    }

    private func windowAdapterIfRuntimeHasBrowserTabs(
        runtimeKey: BrowserWebExtensionRuntimeKey
    ) -> BrowserWebExtensionWindowAdapter? {
        guard tabAdaptersByPanelID.values.contains(where: { adapter in
            adapter.runtimeKey == runtimeKey && adapter.panel != nil
        }) else {
            return nil
        }
        return ensureWindowAdapter(runtimeKey: runtimeKey)
    }

    private func runtimeKey(for panel: BrowserPanel) -> BrowserWebExtensionRuntimeKey {
        runtimeKey(profileID: panel.profileID, websiteDataStore: panel.websiteDataStore)
    }

    private func runtimeKey(
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) -> BrowserWebExtensionRuntimeKey {
        BrowserWebExtensionRuntimeKey(profileID: profileID, websiteDataStore: websiteDataStore)
    }

    private func defaultRuntimeKey(profileID: UUID) -> BrowserWebExtensionRuntimeKey {
        runtimeKey(
            profileID: profileID,
            websiteDataStore: BrowserProfileStore.shared.websiteDataStore(for: profileID)
        )
    }

    private func activeRuntimeKeys(profileID: UUID) -> [BrowserWebExtensionRuntimeKey] {
        let keys = Set(
            controllersByRuntimeKey.keys.filter { $0.profileID == profileID } +
                contextsByRuntimeKey.keys.filter { $0.profileID == profileID }
        )
        return keys.sorted { lhs, rhs in
            String(describing: lhs.dataStoreScope) < String(describing: rhs.dataStoreScope)
        }
    }

    private func profileID(for controller: WKWebExtensionController) -> UUID? {
        runtimeKey(for: controller)?.profileID
    }

    private func runtimeKey(for controller: WKWebExtensionController) -> BrowserWebExtensionRuntimeKey? {
        controllersByRuntimeKey.first { $0.value === controller }?.key
    }

    private func profileID(for context: WKWebExtensionContext) -> UUID? {
        runtimeKey(for: context)?.profileID
    }

    private func runtimeKey(for context: WKWebExtensionContext) -> BrowserWebExtensionRuntimeKey? {
        for (runtimeKey, contexts) in contextsByRuntimeKey {
            if contexts.values.contains(where: { $0 === context }) {
                return runtimeKey
            }
        }
        return nil
    }

    private func extensionWebViewConfiguration(
        for url: URL?,
        context: WKWebExtensionContext
    ) -> WKWebViewConfiguration? {
        guard let url,
              let targetContext = context.webExtensionController?.extensionContext(for: url),
              targetContext === context else {
            return nil
        }
        return context.webViewConfiguration
    }

    private func auxiliaryWebViewConfiguration(
        initialURL: URL?,
        context: WKWebExtensionContext,
        openerPanel: BrowserPanel?,
        shouldBePrivate: Bool
    ) -> BrowserWebExtensionAuxiliaryWebViewConfiguration? {
        let sourceRuntimeKey = runtimeKey(for: context)
            ?? defaultRuntimeKey(profileID: BrowserProfileStore.shared.builtInDefaultProfileID)
        let sourceDataStore = websiteDataStoresByRuntimeKey[sourceRuntimeKey]
            ?? BrowserProfileStore.shared.websiteDataStore(for: sourceRuntimeKey.profileID)
        if !shouldBePrivate,
           let initialURL,
           let targetContext = context.webExtensionController?.extensionContext(for: initialURL),
           targetContext === context {
            guard let extensionConfiguration = context.webViewConfiguration else { return nil }
            return BrowserWebExtensionAuxiliaryWebViewConfiguration(
                runtimeKey: sourceRuntimeKey,
                webViewConfiguration: extensionConfiguration
            )
        }

        let configuration = WKWebViewConfiguration()
        let targetRuntimeKey: BrowserWebExtensionRuntimeKey
        if let browserContext = openerPanel?.popupBrowserContext {
            let targetDataStore = shouldBePrivate
                ? WKWebsiteDataStore.nonPersistent()
                : browserContext.websiteDataStore
            BrowserPanel.configureWebViewConfiguration(
                configuration,
                profileID: browserContext.profileID,
                websiteDataStore: targetDataStore,
                processPool: browserContext.processPool
            )
            targetRuntimeKey = runtimeKey(
                profileID: browserContext.profileID,
                websiteDataStore: targetDataStore
            )
        } else {
            let targetDataStore = shouldBePrivate ? WKWebsiteDataStore.nonPersistent() : sourceDataStore
            BrowserPanel.configureWebViewConfiguration(
                configuration,
                profileID: sourceRuntimeKey.profileID,
                websiteDataStore: targetDataStore
            )
            targetRuntimeKey = runtimeKey(
                profileID: sourceRuntimeKey.profileID,
                websiteDataStore: targetDataStore
            )
        }
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return BrowserWebExtensionAuxiliaryWebViewConfiguration(
            runtimeKey: targetRuntimeKey,
            webViewConfiguration: configuration
        )
    }

    private func loadInstalledRecordsIfNeeded(
        runtimeKey: BrowserWebExtensionRuntimeKey,
        websiteDataStore: WKWebsiteDataStore
    ) async {
        guard !loadedRuntimeKeys.contains(runtimeKey) else { return }
        loadedRuntimeKeys.insert(runtimeKey)
        for record in store.records where record.profileState(for: runtimeKey.profileID).isEnabled {
            do {
                try await load(record: record, runtimeKey: runtimeKey, websiteDataStore: websiteDataStore)
            } catch {
                try? store.setLastError(error.localizedDescription, for: record.id, profileID: runtimeKey.profileID)
            }
        }
        postDidChange()
    }

    private func load(record: BrowserWebExtensionInstallRecord, profileID: UUID) async throws {
        var keys = activeRuntimeKeys(profileID: profileID)
        if keys.isEmpty {
            keys = [defaultRuntimeKey(profileID: profileID)]
        }

        var firstError: Error?
        for runtimeKey in keys {
            let dataStore = websiteDataStoresByRuntimeKey[runtimeKey]
                ?? BrowserProfileStore.shared.websiteDataStore(for: profileID)
            do {
                try await load(record: record, runtimeKey: runtimeKey, websiteDataStore: dataStore)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func load(
        record: BrowserWebExtensionInstallRecord,
        runtimeKey: BrowserWebExtensionRuntimeKey,
        websiteDataStore: WKWebsiteDataStore
    ) async throws {
        let profileID = runtimeKey.profileID
        let controller = ensureController(
            runtimeKey: runtimeKey,
            defaultWebsiteDataStore: websiteDataStore
        )
        if let existing = contextsByRuntimeKey[runtimeKey]?[record.id] {
            cancelBackgroundLoadTask(recordID: record.id, runtimeKey: runtimeKey)
            try? controller.unload(existing)
            contextsByRuntimeKey[runtimeKey]?[record.id] = nil
        }

        let source = BrowserWebExtensionInstallSource(
            kind: record.sourceKind,
            url: URL(fileURLWithPath: record.sourcePath)
        )
        let webExtension = try await loadWebExtension(from: source)
        let context = WKWebExtensionContext(for: webExtension)
        if let uniqueIdentifier = browserWebExtensionContextUniqueIdentifier(
            for: record,
            profileID: profileID,
            dataStoreSuffix: runtimeKey.contextUniqueIdentifierDataStoreSuffix
        ) {
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
        for rawPermission in browserWebExtensionHostGrantablePermissionNames(
            from: profileState.deniedPermissions,
            sourceKind: record.sourceKind
        ) {
            context.setPermissionStatus(
                .deniedExplicitly,
                for: WKWebExtension.Permission(rawPermission)
            )
        }
        for rawURL in profileState.grantedPermissionURLs {
            if let url = URL(string: rawURL) {
                context.setPermissionStatus(.grantedExplicitly, for: url)
            }
        }
        for rawURL in profileState.deniedPermissionURLs {
            if let url = URL(string: rawURL) {
                context.setPermissionStatus(.deniedExplicitly, for: url)
            }
        }
        for rawPattern in profileState.grantedPermissionMatchPatterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: rawPattern) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
        for rawPattern in profileState.deniedPermissionMatchPatterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: rawPattern) {
                context.setPermissionStatus(.deniedExplicitly, for: pattern)
            }
        }
        contextsByRuntimeKey[runtimeKey, default: [:]][record.id] = context
        do {
            try controller.load(context)
        } catch {
            contextsByRuntimeKey[runtimeKey]?[record.id] = nil
            let loadError = BrowserWebExtensionInstallError.loadFailed(error.localizedDescription)
            try? store.setLastError(loadError.localizedDescription, for: record.id, profileID: profileID)
            throw loadError
        }
        try? store.setLastError(nil, for: record.id, profileID: profileID)
        if webExtension.hasBackgroundContent {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await context.loadBackgroundContent()
                } catch {
                    guard !Task.isCancelled else { return }
                    guard let currentContext = self.contextsByRuntimeKey[runtimeKey]?[record.id],
                          currentContext === context else { return }
#if DEBUG
                    cmuxDebugLog(
                        "browser.extensions.background.loadFailed label=\(record.displayName) error=\(error.localizedDescription)"
                    )
#endif
                    try? self.store.setLastError(
                        BrowserWebExtensionInstallError.loadFailed(error.localizedDescription).localizedDescription,
                        for: record.id,
                        profileID: profileID
                    )
                    self.postDidChange()
                }
                self.backgroundLoadTasksByRuntimeKey[runtimeKey]?[record.id] = nil
            }
            backgroundLoadTasksByRuntimeKey[runtimeKey, default: [:]][record.id] = task
        }
    }

    private func unload(recordID: UUID, profileID: UUID) {
        for runtimeKey in activeRuntimeKeys(profileID: profileID) {
            unload(recordID: recordID, runtimeKey: runtimeKey)
        }
    }

    private func unload(recordID: UUID, runtimeKey: BrowserWebExtensionRuntimeKey) {
        guard let context = contextsByRuntimeKey[runtimeKey]?[recordID] else { return }
        cancelBackgroundLoadTask(recordID: recordID, runtimeKey: runtimeKey)
        try? controllersByRuntimeKey[runtimeKey]?.unload(context)
        contextsByRuntimeKey[runtimeKey]?[recordID] = nil
        if contextsByRuntimeKey[runtimeKey]?.isEmpty == true {
            contextsByRuntimeKey[runtimeKey] = nil
        }
    }

    private func loadWebExtension(from source: BrowserWebExtensionInstallSource) async throws -> WKWebExtension {
        do {
            switch source.kind {
            case .appExtensionBundle:
                guard let bundle = Bundle(url: source.url) else {
                    throw BrowserWebExtensionInstallError.unsupportedSource(source.url)
                }
                return try await WKWebExtension(appExtensionBundle: bundle)
            }
        } catch let installError as BrowserWebExtensionInstallError {
            throw installError
        } catch {
            browserWebExtensionLogger.error(
                "Failed to load extension bundle: \(error.localizedDescription, privacy: .private)"
            )
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
                defaultValue: "%@\n\nSource: %@\nAPI permissions: %@\nWebsite access: %@\n\ncmux grants only these permissions and lets the system browser engine enforce extension isolation, host access, and runtime permission prompts."
            ),
            extensionName,
            browserWebExtensionSourceDescription(for: sourceKind),
            permissionsLine,
            hostsLine
        )
    }

    private func runModal(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = modalHostWindow() else {
            return .alertSecondButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private func runRuntimePermissionModal(
        _ alert: NSAlert,
        promptID: UUID
    ) async -> NSApplication.ModalResponse {
        guard let window = modalHostWindow() else {
            return .alertSecondButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.runtimePermissionPromptWindows[promptID] = nil
                continuation.resume(returning: response)
            }
            runtimePermissionPromptWindows[promptID] = alert.window
        }
    }

    private func modalHostWindow() -> NSWindow? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           isInteractiveModalHostWindow(window) {
            return window
        }
        return NSApp.windows.first(where: isInteractiveModalHostWindow)
    }

    private func isInteractiveModalHostWindow(_ window: NSWindow) -> Bool {
        window.isVisible &&
            !window.isMiniaturized &&
            window.alphaValue > 0.001 &&
            !window.ignoresMouseEvents
    }

    private func cancelBackgroundLoadTask(recordID: UUID, runtimeKey: BrowserWebExtensionRuntimeKey) {
        backgroundLoadTasksByRuntimeKey[runtimeKey]?[recordID]?.cancel()
        backgroundLoadTasksByRuntimeKey[runtimeKey]?[recordID] = nil
        if backgroundLoadTasksByRuntimeKey[runtimeKey]?.isEmpty == true {
            backgroundLoadTasksByRuntimeKey[runtimeKey] = nil
        }
    }

    private func cancelAllBackgroundLoadTasks() {
        for tasksByRecordID in backgroundLoadTasksByRuntimeKey.values {
            for task in tasksByRecordID.values {
                task.cancel()
            }
        }
        backgroundLoadTasksByRuntimeKey.removeAll()
    }

    private func requiredMatchPatternStrings(for webExtension: WKWebExtension) -> [String] {
        let requestedPatterns = webExtension.requestedPermissionMatchPatterns.map(\.string)
        let injectedContentPatterns = webExtension.allRequestedMatchPatterns.map(\.string)
        return Array(Set(requestedPatterns + injectedContentPatterns)).sorted()
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: BrowserWebExtensionSupport.didChangeNotification, object: nil)
    }

    private func isSameTab(_ lhs: (any WKWebExtensionTab)?, _ rhs: any WKWebExtensionTab) -> Bool {
        guard let lhs else { return false }
        return (lhs as AnyObject) === (rhs as AnyObject)
    }

    private func noteActiveTab(
        _ tab: any WKWebExtensionTab,
        runtimeKey: BrowserWebExtensionRuntimeKey,
        focusedWindow: (any WKWebExtensionWindow)?
    ) {
        guard let controller = controllersByRuntimeKey[runtimeKey] else { return }
        if let focusedWindow {
            controller.didFocusWindow(focusedWindow)
        }
        let previousTab = activeTabsByRuntimeKey[runtimeKey]
        guard !isSameTab(previousTab, tab) else { return }
        activeTabsByRuntimeKey[runtimeKey] = tab
        controller.didActivateTab(tab, previousActiveTab: previousTab)
        postDidChange()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        let runtimeKey = runtimeKey(for: controller)
        let auxiliaryWindows = auxiliaryWindowAdaptersByID.values
            .filter { runtimeKey == nil || $0.runtimeKey == runtimeKey }
            .filter(\.isVisible)
            .sorted { $0.createdAt < $1.createdAt }
        let windowAdapter = runtimeKey.flatMap { windowAdapterIfRuntimeHasBrowserTabs(runtimeKey: $0) }
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
        let runtimeKey = runtimeKey(for: controller)
        if let focusedAuxiliaryWindow = auxiliaryWindowAdaptersByID.values.first(where: {
            $0.isKeyWindow && (runtimeKey == nil || $0.runtimeKey == runtimeKey)
        }) {
            return focusedAuxiliaryWindow
        }
        let window = runtimeKey.flatMap { windowAdapterIfRuntimeHasBrowserTabs(runtimeKey: $0) }
        return window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        let runtimeKey = runtimeKey(for: controller)
            ?? defaultRuntimeKey(profileID: BrowserProfileStore.shared.builtInDefaultProfileID)
        let opener = configuration.tabs.compactMap { ($0 as? BrowserWebExtensionTabAdapter)?.panel }.first
            ?? activeTabAdapter(runtimeKey: runtimeKey)?.panel
            ?? tabAdaptersByPanelID.values.filter { $0.runtimeKey == runtimeKey }.compactMap(\.panel).first
        let initialURL = configuration.tabURLs.first
        guard let auxiliaryConfiguration = auxiliaryWebViewConfiguration(
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
            runtimeKey: auxiliaryConfiguration.runtimeKey,
            recordID: recordID(for: context),
            configuration: configuration,
            webViewConfiguration: auxiliaryConfiguration.webViewConfiguration,
            customUserAgent: BrowserUserAgentSettings.safariUserAgent,
            initialURL: initialURL,
            openerPanel: opener
        )
        auxiliaryWindowAdaptersByID[window.id] = window
        let targetController = controllersByRuntimeKey[auxiliaryConfiguration.runtimeKey] ?? controller
        targetController.didOpenWindow(window)
        targetController.didOpenTab(window.tabAdapter)
        if configuration.shouldBeFocused {
            noteActiveTab(window.tabAdapter, runtimeKey: auxiliaryConfiguration.runtimeKey, focusedWindow: window)
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
        let runtimeKey = runtimeKey(for: controller)
            ?? defaultRuntimeKey(profileID: BrowserProfileStore.shared.builtInDefaultProfileID)
        let opener = (configuration.parentTab as? BrowserWebExtensionTabAdapter)?.panel
            ?? activeTabAdapter(runtimeKey: runtimeKey)?.panel
            ?? tabAdaptersByPanelID.values.filter { $0.runtimeKey == runtimeKey }.compactMap(\.panel).first
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
        let extensionConfiguration = extensionWebViewConfiguration(
            for: configuration.url,
            context: context
        )
        let opensExtensionURL = configuration.url.map { url in
            context.webExtensionController?.extensionContext(for: url) === context
        } ?? false
        guard !opensExtensionURL || extensionConfiguration != nil else {
            completionHandler(nil, nil)
            return
        }
        let createdPanel = workspace.newBrowserSurface(
            inPane: paneId,
            url: opensExtensionURL ? nil : configuration.url,
            focus: configuration.shouldBeActive,
            insertAtEnd: true,
            preferredProfileID: opener.profileID
        )
        if let createdPanel,
           let extensionConfiguration,
           let url = configuration.url {
            createdPanel.loadWebExtensionPage(url, webViewConfiguration: extensionConfiguration)
        }
        completionHandler(createdPanel.flatMap { tabAdaptersByPanelID[$0.id] }, nil)
    }

    fileprivate func auxiliaryWindowDidFocus(_ window: BrowserWebExtensionAuxiliaryWindowAdapter) {
        noteActiveTab(window.tabAdapter, runtimeKey: window.runtimeKey, focusedWindow: window)
    }

    fileprivate func auxiliaryWindowDidChangeTabProperties(
        _ properties: WKWebExtension.TabChangedProperties,
        tab: BrowserWebExtensionAuxiliaryTabAdapter
    ) {
        controllersByRuntimeKey[tab.runtimeKey]?.didChangeTabProperties(properties, for: tab)
    }

    fileprivate func auxiliaryWindowDidClose(_ window: BrowserWebExtensionAuxiliaryWindowAdapter) {
        let runtimeKey = window.runtimeKey
        auxiliaryWindowAdaptersByID.removeValue(forKey: window.id)
        controllersByRuntimeKey[runtimeKey]?.didCloseTab(window.tabAdapter, windowIsClosing: true)
        controllersByRuntimeKey[runtimeKey]?.didCloseWindow(window)
        if isSameTab(activeTabsByRuntimeKey[runtimeKey], window.tabAdapter) {
            activeTabsByRuntimeKey[runtimeKey] = nil
        }
        cleanupTransientRuntimeIfUnused(runtimeKey)
        postDidChange()
    }

    private func cleanupTransientRuntimeIfUnused(_ runtimeKey: BrowserWebExtensionRuntimeKey) {
        guard runtimeKey.isTransient else { return }
        let hasBrowserTab = tabAdaptersByPanelID.values.contains { adapter in
            adapter.runtimeKey == runtimeKey && adapter.panel != nil
        }
        guard !hasBrowserTab else { return }
        guard !auxiliaryWindowAdaptersByID.values.contains(where: { $0.runtimeKey == runtimeKey }) else { return }

        if let tasksByRecordID = backgroundLoadTasksByRuntimeKey[runtimeKey] {
            for task in tasksByRecordID.values {
                task.cancel()
            }
        }
        if let controller = controllersByRuntimeKey[runtimeKey],
           let contextsByRecordID = contextsByRuntimeKey[runtimeKey] {
            for context in contextsByRecordID.values {
                try? controller.unload(context)
            }
        }
        backgroundLoadTasksByRuntimeKey[runtimeKey] = nil
        contextsByRuntimeKey[runtimeKey] = nil
        controllersByRuntimeKey[runtimeKey]?.delegate = nil
        controllersByRuntimeKey[runtimeKey] = nil
        websiteDataStoresByRuntimeKey[runtimeKey] = nil
        windowAdaptersByRuntimeKey[runtimeKey] = nil
        activeTabsByRuntimeKey[runtimeKey] = nil
        loadedRuntimeKeys.remove(runtimeKey)
    }

    private func closeAllAuxiliaryWindows() {
        let windows = Array(auxiliaryWindowAdaptersByID.values)
        for window in windows {
            window.closeWindow()
        }
    }

    private func closeAuxiliaryWindows(recordID: UUID, profileID: UUID? = nil) {
        let windows = auxiliaryWindowAdaptersByID.values.filter { window in
            window.recordID == recordID && (profileID == nil || window.profileID == profileID)
        }
        for window in windows {
            window.closeWindow()
        }
    }

    private func closeActionPopup(forPanelID panelID: UUID) {
        let presentations = actionPopupPresentationsByID.values.filter { $0.panelID == panelID }
        for presentation in presentations {
            presentation.close()
        }
        activeActionPopupByPanelID.removeValue(forKey: panelID)
        for presentation in presentations {
            actionPopupPresentationsByID.removeValue(forKey: presentation.id)
        }
    }

    fileprivate func actionPopupDidClose(_ presentation: BrowserWebExtensionActionPopupPresentation) {
        actionPopupPresentationsByID.removeValue(forKey: presentation.id)
        if let panelID = presentation.panelID,
           activeActionPopupByPanelID[panelID]?.presentationID == presentation.id {
            activeActionPopupByPanelID.removeValue(forKey: panelID)
            postDidChange()
        }
    }

    private func closeAllActionPopups() {
        let presentations = Array(actionPopupPresentationsByID.values)
        for presentation in presentations {
            presentation.close()
        }
        let closedPresentationIDs = Set(presentations.map(\.id))
        let activePanelIDsToClear = activeActionPopupByPanelID.compactMap { panelID, state in
            closedPresentationIDs.contains(state.presentationID) ? panelID : nil
        }
        for panelID in activePanelIDsToClear {
            activeActionPopupByPanelID.removeValue(forKey: panelID)
        }
        if !activePanelIDsToClear.isEmpty {
            postDidChange()
        }
        actionPopupPresentationsByID.removeAll()
    }

    private func closeActionPopups(recordID: UUID, profileID: UUID? = nil) {
        let presentations = actionPopupPresentationsByID.values.filter { presentation in
            guard presentation.actionID == recordID else { return false }
            guard let profileID else { return true }
            guard let panelID = presentation.panelID,
                  let adapter = tabAdaptersByPanelID[panelID] else {
                return false
            }
            return adapter.runtimeKey.profileID == profileID
        }
        for presentation in presentations {
            presentation.close()
        }
    }

    private func showActionPopup(
        _ action: WKWebExtension.Action,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let popupPopover = action.popupPopover
        let actionPanel = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel
            ?? activeTabAdapter()?.panel
        guard action.isEnabled,
              action.presentsPopup,
              let popupWebView = action.popupWebView,
              let actionPanel,
              let anchorWindow = actionPanel.webView.window
        else {
            completionHandler(nil)
            return
        }
#if DEBUG
        popupWebView.isInspectable = true
#endif
        let anchorScreenRect = actionPopupAnchorScreenRect(
            forPanelID: actionPanel.id,
            fallbackView: actionPanel.webView
        )
        closeAllActionPopups()
        let presentation = BrowserWebExtensionActionPopupPresentation(
            action: action,
            panelID: actionPanel.id,
            actionID: action.webExtensionContext.flatMap { recordID(for: $0) },
            popupWebView: popupWebView,
            requestedContentSize: popupPopover?.contentSize ?? .zero,
            runtime: self
        )
        actionPopupPresentationsByID[presentation.id] = presentation
        presentation.show(
            anchorScreenRect: anchorScreenRect,
            in: anchorWindow
        )
        if let panelID = presentation.panelID,
           let actionID = presentation.actionID {
            activeActionPopupByPanelID[panelID] = BrowserWebExtensionActivePopupState(
                presentationID: presentation.id,
                actionID: actionID
            )
            postDidChange()
        }
        completionHandler(nil)
    }

    private func actionSnapshot(
        recordID: UUID,
        context: WKWebExtensionContext,
        tab: BrowserWebExtensionTabAdapter
    ) -> BrowserWebExtensionActionSnapshot? {
        guard let action = context.action(for: tab) else { return nil }
        return BrowserWebExtensionActionSnapshot(
            id: recordID,
            label: action.label,
            badgeText: action.badgeText,
            isEnabled: action.isEnabled,
            iconPNGData: browserWebExtensionActionIconPNGData(for: action)
        )
    }

    private func recordID(for context: WKWebExtensionContext) -> UUID? {
        guard let runtimeKey = runtimeKey(for: context) else { return nil }
        return contextsByRuntimeKey[runtimeKey]?.first { _, candidateContext in
            candidateContext === context
        }?.key
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
        let recordID = recordID(for: context)
        let profileID = profileID(for: context)
        promptForRuntimePermission(message: message) { [weak self] allowed in
            if let self,
               let recordID,
               let profileID {
                try? self.store.recordRuntimePermissionDecision(
                    granted: allowed,
                    permissions: grantablePermissions.map { String($0.rawValue) },
                    for: recordID,
                    profileID: profileID
                )
                self.postDidChange()
            }
            completionHandler(allowed ? grantablePermissions : [], nil)
        }
    }

    private func sourceKind(for context: WKWebExtensionContext) -> BrowserWebExtensionInstallRecord.SourceKind {
        guard let recordID = recordID(for: context),
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
        let recordID = recordID(for: context)
        let profileID = profileID(for: context)
        promptForRuntimePermission(message: message) { [weak self] allowed in
            if let self,
               let recordID,
               let profileID {
                try? self.store.recordRuntimePermissionDecision(
                    granted: allowed,
                    permissionURLs: urls.map(\.absoluteString),
                    for: recordID,
                    profileID: profileID
                )
                self.postDidChange()
            }
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
        let recordID = recordID(for: context)
        let profileID = profileID(for: context)
        promptForRuntimePermission(message: message) { [weak self] allowed in
            if let self,
               let recordID,
               let profileID {
                try? self.store.recordRuntimePermissionDecision(
                    granted: allowed,
                    permissionMatchPatterns: matchPatterns.map(\.string),
                    for: recordID,
                    profileID: profileID
                )
                self.postDidChange()
            }
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

    private func actionPopupAnchorScreenRect(forPanelID panelID: UUID, fallbackView: NSView) -> NSRect {
        if let view = actionPopupAnchorViewsByPanelID[panelID]?.view,
           view.window != nil {
            updateActionPopupAnchorScreenRect(view, forPanelID: panelID)
        }
        if let screenRect = actionPopupAnchorScreenRectsByPanelID[panelID],
           !screenRect.isEmpty {
            return screenRect
        }
        let rectInWindow = fallbackView.convert(fallbackView.bounds, to: nil)
        return fallbackView.window?.convertToScreen(rectInWindow) ?? rectInWindow
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
        let promptID = UUID()
        runtimePermissionPromptDenyHandlers[promptID] = {
            completion(false)
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                completion(false)
                return
            }
            let response = await runRuntimePermissionModal(alert, promptID: promptID)
            guard self.runtimePermissionPromptDenyHandlers.removeValue(forKey: promptID) != nil else {
                return
            }
            self.runtimePermissionPromptTasks[promptID] = nil
            completion(response == .alertFirstButtonReturn)
        }
        runtimePermissionPromptTasks[promptID] = task
    }

    private func cancelRuntimePermissionPrompts() {
        let denyHandlers = runtimePermissionPromptDenyHandlers
        runtimePermissionPromptDenyHandlers.removeAll()
        let promptWindows = runtimePermissionPromptWindows
        runtimePermissionPromptWindows.removeAll()
        for promptWindow in promptWindows.values {
            if let sheetParent = promptWindow.sheetParent {
                sheetParent.endSheet(promptWindow, returnCode: .alertSecondButtonReturn)
            } else {
                promptWindow.close()
            }
        }
        for task in runtimePermissionPromptTasks.values {
            task.cancel()
        }
        runtimePermissionPromptTasks.removeAll()
        for handler in denyHandlers.values {
            handler()
        }
    }

    private func shouldNotifyWindowFocus(for panel: BrowserPanel) -> Bool {
        if let focusedPanelID = AppDelegate.shared?.tabManager?.selectedWorkspace?.focusedPanelId {
            return focusedPanelID == panel.id
        }
        return panel.webView.window?.isKeyWindow == true
    }

    fileprivate func activeTabAdapter(runtimeKey: BrowserWebExtensionRuntimeKey? = nil) -> BrowserWebExtensionTabAdapter? {
        if let focusedPanelID = AppDelegate.shared?.tabManager?.selectedWorkspace?.focusedPanelId,
           let adapter = tabAdaptersByPanelID[focusedPanelID],
           runtimeKey == nil || adapter.runtimeKey == runtimeKey {
            return adapter
        }
        return tabAdaptersByPanelID.values.first { adapter in
            guard runtimeKey == nil || adapter.runtimeKey == runtimeKey else { return false }
            return adapter.panel?.webView.window?.isKeyWindow == true
        }
    }

    fileprivate func tabAdapters(runtimeKey: BrowserWebExtensionRuntimeKey) -> [BrowserWebExtensionTabAdapter] {
        var seenPanelIDs: Set<UUID> = []
        var orderedAdapters: [BrowserWebExtensionTabAdapter] = []

        if let tabManager = AppDelegate.shared?.tabManager {
            for workspace in tabManager.tabs {
                for panelID in workspace.sidebarOrderedPanelIds() where seenPanelIDs.insert(panelID).inserted {
                    if let adapter = tabAdaptersByPanelID[panelID],
                       adapter.runtimeKey == runtimeKey {
                        orderedAdapters.append(adapter)
                    }
                }
            }
        }

        let fallbackPanelIDs = tabAdaptersByPanelID.keys.sorted { $0.uuidString < $1.uuidString }
        for panelID in fallbackPanelIDs where seenPanelIDs.insert(panelID).inserted {
            if let adapter = tabAdaptersByPanelID[panelID],
               adapter.runtimeKey == runtimeKey {
                orderedAdapters.append(adapter)
            }
        }
        return orderedAdapters
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionActionPopupWindow: NSPanel {
    weak var popupPresentation: BrowserWebExtensionActionPopupPresentation?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        guard let popupPresentation else {
            super.performClose(sender)
            return
        }
        popupPresentation.close()
    }

    override func cancelOperation(_ sender: Any?) {
        guard let popupPresentation else {
            super.cancelOperation(sender)
            return
        }
        popupPresentation.close()
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionActionPopupFrameView: NSView {
    let contentContainer = NSView()
    var arrowMidX: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }
    let arrowHeight: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = 10
        contentContainer.layer?.cornerCurve = .continuous
        contentContainer.layer?.masksToBounds = true
        addSubview(contentContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        contentContainer.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(0, bounds.height - arrowHeight)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let arrowHalfWidth: CGFloat = 9
        let arrowBaseY = bounds.maxY - arrowHeight
        let path = NSBezierPath()
        path.move(to: NSPoint(x: arrowMidX, y: bounds.maxY))
        path.line(to: NSPoint(x: arrowMidX - arrowHalfWidth, y: arrowBaseY))
        path.line(to: NSPoint(x: arrowMidX + arrowHalfWidth, y: arrowBaseY))
        path.close()
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionActionPopupPresentation: NSObject, NSWindowDelegate, WKUIDelegate {
    let id = UUID()
    let panelID: UUID?
    let actionID: UUID?
    private let frameView = BrowserWebExtensionActionPopupFrameView()
    private let action: WKWebExtension.Action
    private let requestedContentSize: CGSize
    private let popupWebView: WKWebView
    private weak var previousUIDelegate: (any WKUIDelegate)?
    private weak var runtime: BrowserWebExtensionRuntime?
    private weak var parentWindow: NSWindow?
    private var popupWindow: BrowserWebExtensionActionPopupWindow?
    private var outsideClickMonitor: Any?
    private var didClosePopup = false

    init(
        action: WKWebExtension.Action,
        panelID: UUID?,
        actionID: UUID?,
        popupWebView: WKWebView,
        requestedContentSize: CGSize,
        runtime: BrowserWebExtensionRuntime
    ) {
        self.action = action
        self.panelID = panelID
        self.actionID = actionID
        self.popupWebView = popupWebView
        self.requestedContentSize = requestedContentSize
        self.previousUIDelegate = popupWebView.uiDelegate
        self.runtime = runtime
        super.init()

        popupWebView.removeFromSuperview()
        popupWebView.translatesAutoresizingMaskIntoConstraints = false
        frameView.contentContainer.addSubview(popupWebView)
        NSLayoutConstraint.activate([
            popupWebView.leadingAnchor.constraint(equalTo: frameView.contentContainer.leadingAnchor),
            popupWebView.trailingAnchor.constraint(equalTo: frameView.contentContainer.trailingAnchor),
            popupWebView.topAnchor.constraint(equalTo: frameView.contentContainer.topAnchor),
            popupWebView.bottomAnchor.constraint(equalTo: frameView.contentContainer.bottomAnchor)
        ])
        popupWebView.uiDelegate = self
    }

    func show(
        anchorScreenRect: NSRect,
        in anchorWindow: NSWindow
    ) {
        let visibleFrame = anchorWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: CGSize(width: 800, height: 600))
        let requestedSize = requestedContentSize.width > 0 || requestedContentSize.height > 0
            ? requestedContentSize
            : popupWebView.frame.size
        let contentSize = browserWebExtensionActionPopupContentSize(
            requestedSize: requestedSize,
            visibleFrame: visibleFrame
        )
        let hostFrame = anchorWindow.frame.intersection(visibleFrame)
        let allowedFrame = hostFrame.isNull || hostFrame.isEmpty ? visibleFrame : hostFrame
        let layout = browserWebExtensionActionPopupWindowLayout(
            anchorScreenRect: anchorScreenRect,
            contentSize: contentSize,
            allowedFrame: allowedFrame,
            arrowHeight: frameView.arrowHeight
        )
        frameView.arrowMidX = layout.arrowMidX
        frameView.setFrameSize(layout.frame.size)
        popupWebView.setFrameSize(contentSize)

        let popupWindow = BrowserWebExtensionActionPopupWindow(
            contentRect: layout.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        popupWindow.identifier = NSUserInterfaceItemIdentifier("cmux.browser-extension-action-popup")
        popupWindow.popupPresentation = self
        popupWindow.isReleasedWhenClosed = false
        popupWindow.isOpaque = false
        popupWindow.backgroundColor = .clear
        popupWindow.hasShadow = true
        popupWindow.level = anchorWindow.level
        popupWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        popupWindow.contentView = frameView
        popupWindow.delegate = self
        popupWindow.setFrame(layout.frame, display: true)
        anchorWindow.addChildWindow(popupWindow, ordered: .above)
        popupWindow.makeKeyAndOrderFront(nil)
        parentWindow = anchorWindow
        self.popupWindow = popupWindow
        installOutsideClickMonitor()
    }

    func close() {
        if let popupWindow {
            self.popupWindow = nil
            popupWindow.delegate = nil
            parentWindow?.removeChildWindow(popupWindow)
            popupWindow.close()
        }
        closeWebExtensionPopupIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow,
           popupWindow === closingWindow {
            popupWindow = nil
            parentWindow?.removeChildWindow(closingWindow)
        }
        closeWebExtensionPopupIfNeeded()
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  let popupWindow = self.popupWindow
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
        runtime?.actionPopupDidClose(self)
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
    let runtimeKey: BrowserWebExtensionRuntimeKey
    let profileID: UUID
    let recordID: UUID?
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
        runtimeKey: BrowserWebExtensionRuntimeKey,
        recordID: UUID?,
        configuration: WKWebExtension.WindowConfiguration,
        webViewConfiguration: WKWebViewConfiguration,
        customUserAgent: String,
        initialURL: URL?,
        openerPanel: BrowserPanel?
    ) {
        self.runtime = runtime
        self.runtimeKey = runtimeKey
        self.profileID = runtimeKey.profileID
        self.recordID = recordID
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
        self.tabAdapter = BrowserWebExtensionAuxiliaryTabAdapter(webView: webView, runtimeKey: runtimeKey)

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
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let contentRect = browserWebExtensionAuxiliaryWindowContentRect(
            requestedFrame: frame,
            visibleFrame: visibleFrame,
            defaultSize: panel.frame.size,
            minSize: CGSize(width: 260, height: 180)
        )
        panel.setFrame(contentRect, display: true)
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
    let runtimeKey: BrowserWebExtensionRuntimeKey
    let profileID: UUID

    init(webView: WKWebView, runtimeKey: BrowserWebExtensionRuntimeKey) {
        self.webView = webView
        self.runtimeKey = runtimeKey
        self.profileID = runtimeKey.profileID
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
        guard webView?.isLoading == true else { return nil }
        return webView?.url
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
        guard let windowAdapter else {
            completionHandler(nil)
            return
        }
        windowAdapter.focus(for: context, completionHandler: completionHandler)
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
    let runtimeKey: BrowserWebExtensionRuntimeKey
    let profileID: UUID

    init(runtimeKey: BrowserWebExtensionRuntimeKey) {
        self.runtimeKey = runtimeKey
        self.profileID = runtimeKey.profileID
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        runtimeTabAdapters()
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        runtime?.activeTabAdapter(runtimeKey: runtimeKey) ?? runtimeTabAdapters().first
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = runtime?.activeTabAdapter(runtimeKey: runtimeKey)?.panel?.webView.window ?? NSApp.keyWindow else {
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
        (runtime?.activeTabAdapter(runtimeKey: runtimeKey)?.panel?.webView.window ?? NSApp.keyWindow)?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (runtime?.activeTabAdapter(runtimeKey: runtimeKey)?.panel?.webView.window ?? NSApp.keyWindow)?.screen?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let panel = runtime?.activeTabAdapter(runtimeKey: runtimeKey)?.panel {
            BrowserWebExtensionTabAdapter.activateOwningBrowserPanel(panel)
        }
        completionHandler(nil)
    }

    private func runtimeTabAdapters() -> [BrowserWebExtensionTabAdapter] {
        runtime?.tabAdapters(runtimeKey: runtimeKey) ?? []
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var panel: BrowserPanel?
    private weak var windowAdapter: BrowserWebExtensionWindowAdapter?
    let runtimeKey: BrowserWebExtensionRuntimeKey
    let profileID: UUID

    init(panel: BrowserPanel, windowAdapter: BrowserWebExtensionWindowAdapter, runtimeKey: BrowserWebExtensionRuntimeKey) {
        self.panel = panel
        self.windowAdapter = windowAdapter
        self.runtimeKey = runtimeKey
        self.profileID = runtimeKey.profileID
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
        guard panel?.isLoading == true else { return nil }
        return panel.flatMap { BrowserPanel.remoteProxyDisplayURL(for: $0.webView.url) ?? $0.currentURL }
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
        if let panel,
           let extensionConfiguration = context.webViewConfiguration,
           context.webExtensionController?.extensionContext(for: url) === context {
            panel.loadWebExtensionPage(url, webViewConfiguration: extensionConfiguration)
        } else if let panel,
                  let currentURL = panel.webView.url ?? panel.currentURL,
                  context.webExtensionController?.extensionContext(for: currentURL) === context {
            panel.loadBrowserPage(url)
        } else {
            panel?.navigate(to: url)
        }
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
        if let panel {
            Self.activateOwningBrowserPanel(panel)
        }
        completionHandler(nil)
    }

    static func activateOwningBrowserPanel(_ panel: BrowserPanel) {
        guard let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panel.id,
            preferredWorkspaceId: panel.workspaceId
        ) else {
            panel.focus()
            return
        }
        located.tabManager.focusTab(
            located.workspace.id,
            surfaceId: panel.id,
            suppressFlash: true,
            focusIntent: .browser(.webView)
        )
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
