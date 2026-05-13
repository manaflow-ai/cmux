import AppKit
import Foundation
import WebKit

struct BrowserWebExtensionInstalledSummary: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let detail: String
    let isEnabled: Bool
    let isLoaded: Bool
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

struct BrowserWebExtensionHostCapabilityPolicy: Equatable {
    enum Availability: Equatable {
        case delegatedToWebKit
        case hostedByCmux
        case unavailable(UnavailableReason)

        var isAvailable: Bool {
            switch self {
            case .delegatedToWebKit, .hostedByCmux:
                return true
            case .unavailable:
                return false
            }
        }
    }

    enum UnavailableReason: Equatable {
        case missingHostAdapter
        case noPublicWebKitSurface
    }

    struct PermissionCapability: Equatable {
        let name: String
        let availability: Availability
        let appExtensionBundleAvailability: Availability?
        let apiPaths: [String]

        init(
            _ name: String,
            availability: Availability,
            appExtensionBundleAvailability: Availability? = nil,
            apiPaths: [String] = []
        ) {
            self.name = name
            self.availability = availability
            self.appExtensionBundleAvailability = appExtensionBundleAvailability
            self.apiPaths = apiPaths
        }

        func availability(for sourceKind: BrowserWebExtensionInstallRecord.SourceKind) -> Availability {
            if sourceKind == .appExtensionBundle,
               let appExtensionBundleAvailability {
                return appExtensionBundleAvailability
            }
            return availability
        }
    }

    struct APICapability: Equatable {
        let path: String
        let availability: Availability
        let appExtensionBundleAvailability: Availability?

        init(
            _ path: String,
            availability: Availability,
            appExtensionBundleAvailability: Availability? = nil
        ) {
            self.path = path
            self.availability = availability
            self.appExtensionBundleAvailability = appExtensionBundleAvailability
        }

        func availability(for sourceKind: BrowserWebExtensionInstallRecord.SourceKind) -> Availability {
            if sourceKind == .appExtensionBundle,
               let appExtensionBundleAvailability {
                return appExtensionBundleAvailability
            }
            return availability
        }
    }

    static let current = BrowserWebExtensionHostCapabilityPolicy(
        permissions: [
            PermissionCapability("activeTab", availability: .delegatedToWebKit),
            PermissionCapability("alarms", availability: .delegatedToWebKit, apiPaths: ["browser.alarms"]),
            PermissionCapability("bookmarks", availability: .unavailable(.missingHostAdapter), apiPaths: ["browser.bookmarks"]),
            PermissionCapability(
                "clipboardRead",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            PermissionCapability("clipboardWrite", availability: .delegatedToWebKit),
            PermissionCapability("contextMenus", availability: .delegatedToWebKit, apiPaths: ["browser.contextMenus"]),
            PermissionCapability("cookies", availability: .delegatedToWebKit, apiPaths: ["browser.cookies"]),
            PermissionCapability(
                "declarativeNetRequest",
                availability: .delegatedToWebKit,
                apiPaths: ["browser.declarativeNetRequest"]
            ),
            PermissionCapability("declarativeNetRequestFeedback", availability: .delegatedToWebKit),
            PermissionCapability("declarativeNetRequestWithHostAccess", availability: .delegatedToWebKit),
            PermissionCapability("downloads", availability: .unavailable(.missingHostAdapter), apiPaths: ["browser.downloads"]),
            PermissionCapability("favicon", availability: .unavailable(.noPublicWebKitSurface), apiPaths: ["browser.favicon"]),
            PermissionCapability(
                "idle",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit,
                apiPaths: ["browser.idle"]
            ),
            PermissionCapability("management", availability: .unavailable(.missingHostAdapter), apiPaths: ["browser.management"]),
            PermissionCapability("menus", availability: .delegatedToWebKit, apiPaths: ["browser.menus"]),
            PermissionCapability(
                "nativeMessaging",
                availability: .unavailable(.missingHostAdapter),
                appExtensionBundleAvailability: .delegatedToWebKit,
                apiPaths: ["browser.runtime.connectNative", "browser.runtime.sendNativeMessage"]
            ),
            PermissionCapability(
                "notifications",
                availability: .delegatedToWebKit,
                apiPaths: ["browser.notifications"]
            ),
            PermissionCapability(
                "offscreen",
                availability: .unavailable(.noPublicWebKitSurface),
                apiPaths: ["browser.offscreen"]
            ),
            PermissionCapability(
                "privacy",
                availability: .unavailable(.noPublicWebKitSurface),
                apiPaths: ["browser.privacy"]
            ),
            PermissionCapability("scripting", availability: .delegatedToWebKit, apiPaths: ["browser.scripting"]),
            PermissionCapability("storage", availability: .delegatedToWebKit, apiPaths: ["browser.storage"]),
            PermissionCapability("tabs", availability: .hostedByCmux, apiPaths: ["browser.tabs"]),
            PermissionCapability("unlimitedStorage", availability: .delegatedToWebKit),
            PermissionCapability(
                "userScripts",
                availability: .unavailable(.noPublicWebKitSurface),
                apiPaths: ["browser.userScripts"]
            ),
            PermissionCapability("webNavigation", availability: .delegatedToWebKit, apiPaths: ["browser.webNavigation"]),
            PermissionCapability("webRequest", availability: .delegatedToWebKit, apiPaths: ["browser.webRequest"]),
            PermissionCapability("webRequestBlocking", availability: .delegatedToWebKit),
            PermissionCapability(
                "webRequestAuthProvider",
                availability: .unavailable(.missingHostAdapter),
                apiPaths: ["browser.webRequest.onAuthRequired"]
            ),
        ],
        apis: [
            APICapability(
                "browser.clipboardRead",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability("browser.action.getUserSettings", availability: .unavailable(.noPublicWebKitSurface)),
            APICapability("browser.browserAction.getUserSettings", availability: .unavailable(.noPublicWebKitSurface)),
            APICapability("browser.bookmarks", availability: .unavailable(.missingHostAdapter)),
            APICapability("browser.downloads", availability: .unavailable(.missingHostAdapter)),
            APICapability(
                "browser.extension.getBackgroundPage",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability(
                "browser.extension.getViews",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability("browser.favicon", availability: .unavailable(.noPublicWebKitSurface)),
            APICapability(
                "browser.idle",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability("browser.management", availability: .unavailable(.missingHostAdapter)),
            APICapability("browser.notifications", availability: .delegatedToWebKit),
            APICapability("browser.offscreen", availability: .unavailable(.noPublicWebKitSurface)),
            APICapability("browser.privacy", availability: .unavailable(.noPublicWebKitSurface)),
            APICapability(
                "browser.runtime.getBackgroundPage",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability(
                "browser.runtime.getContexts",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability(
                "browser.runtime.connectNative",
                availability: .unavailable(.missingHostAdapter),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability(
                "browser.runtime.sendNativeMessage",
                availability: .unavailable(.missingHostAdapter),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability(
                "browser.storage.managed",
                availability: .unavailable(.noPublicWebKitSurface),
                appExtensionBundleAvailability: .delegatedToWebKit
            ),
            APICapability("browser.userScripts", availability: .unavailable(.noPublicWebKitSurface)),
            APICapability("browser.webRequest.onAuthRequired", availability: .unavailable(.missingHostAdapter)),
        ]
    )

    private let permissionsByName: [String: PermissionCapability]
    private let apiCapabilities: [APICapability]

    init(permissions: [PermissionCapability], apis: [APICapability]) {
        self.permissionsByName = Dictionary(uniqueKeysWithValues: permissions.map { ($0.name, $0) })
        self.apiCapabilities = apis
    }

    func isPermissionGrantable(
        _ rawPermission: String,
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> Bool {
        permissionsByName[rawPermission]?.availability(for: sourceKind).isAvailable == true
    }

    func grantablePermissionNames(
        from rawPermissions: [String],
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> [String] {
        rawPermissions.filter { isPermissionGrantable($0, sourceKind: sourceKind) }
    }

    func unsupportedAPIs(
        forPermissionNames rawPermissions: [String],
        sourceKind: BrowserWebExtensionInstallRecord.SourceKind = .appExtensionBundle
    ) -> Set<String> {
        var unsupportedAPIs = Set(apiCapabilities.flatMap { api in
            api.availability(for: sourceKind).isAvailable ? [] : Self.namespaceAliases(forAPIPath: api.path)
        })

        for rawPermission in rawPermissions {
            guard let permission = permissionsByName[rawPermission],
                  !permission.availability(for: sourceKind).isAvailable else {
                continue
            }
            for apiPath in permission.apiPaths {
                unsupportedAPIs.formUnion(Self.namespaceAliases(forAPIPath: apiPath))
            }
        }

        return unsupportedAPIs
    }

    private static func namespaceAliases(forAPIPath path: String) -> [String] {
        if path.hasPrefix("browser.") {
            let suffix = String(path.dropFirst("browser.".count))
            return [path, "chrome.\(suffix)"]
        }
        if path.hasPrefix("chrome.") {
            let suffix = String(path.dropFirst("chrome.".count))
            return [path, "browser.\(suffix)"]
        }
        return [path]
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
        return String(localized: "browser.extensions.summary.unsupportedLocalExtension", defaultValue: "Unsupported local extension")
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
    for record: BrowserWebExtensionInstallRecord
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
        return bundleIdentifier
    }
}

enum BrowserWebExtensionInstallError: LocalizedError, Equatable {
    case unsupportedOS
    case cancelled
    case noManifest(URL)
    case noWebExtensionInApp(URL)
    case unsupportedSource(URL)
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

    func summaries(loadedRecordIDs: Set<UUID> = []) -> [BrowserWebExtensionInstalledSummary] {
        records.map { record in
            return BrowserWebExtensionInstalledSummary(
                id: record.id,
                displayName: record.displayName,
                detail: browserWebExtensionSummaryDetail(
                    sourceKind: record.sourceKind,
                    displayVersion: record.displayVersion
                ),
                isEnabled: record.isEnabled,
                isLoaded: loadedRecordIDs.contains(record.id)
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

    func discoverSource(from url: URL) throws -> BrowserWebExtensionInstallSource {
        let resolvedURL = url.standardizedFileURL
        let pathExtension = resolvedURL.pathExtension.lowercased()

        if pathExtension == "app" {
            guard let appExtensionURL = firstWebExtensionAppExtension(in: resolvedURL) else {
                throw BrowserWebExtensionInstallError.noWebExtensionInApp(resolvedURL)
            }
            return BrowserWebExtensionInstallSource(kind: .appExtensionBundle, url: appExtensionURL)
        }

        if pathExtension == "appex" {
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
        websiteDataStore: WKWebsiteDataStore
    ) {
        guard #available(macOS 15.4, *) else { return }
        BrowserWebExtensionRuntime.shared.configure(
            configuration,
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

    static func installedExtensionSummaries() -> [BrowserWebExtensionInstalledSummary] {
        guard #available(macOS 15.4, *) else { return [] }
        return BrowserWebExtensionRuntime.shared.installedExtensionSummaries()
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
    private var controller: WKWebExtensionController?
    private var contextsByRecordID: [UUID: WKWebExtensionContext] = [:]
    private var tabAdaptersByPanelID: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var auxiliaryWindowAdaptersByID: [UUID: BrowserWebExtensionAuxiliaryWindowAdapter] = [:]
    private var actionPopupPresentationsByID: [UUID: BrowserWebExtensionActionPopupPresentation] = [:]
    private var actionPopupAnchorViewsByPanelID: [UUID: BrowserWebExtensionWeakView] = [:]
    private let windowAdapter = BrowserWebExtensionWindowAdapter()
    private var hasLoadedRecords = false

    override init() {
        super.init()
        windowAdapter.runtime = self
    }

    func configure(
        _ configuration: WKWebViewConfiguration,
        websiteDataStore: WKWebsiteDataStore
    ) {
        let controller = ensureController(defaultWebsiteDataStore: websiteDataStore)
        configuration.webExtensionController = controller
    }

    func register(panel: BrowserPanel) {
        let existingAdapter = tabAdaptersByPanelID[panel.id]
        let adapter = existingAdapter ?? BrowserWebExtensionTabAdapter(panel: panel, windowAdapter: windowAdapter)
        adapter.panel = panel
        tabAdaptersByPanelID[panel.id] = adapter
        if existingAdapter == nil {
            controller?.didOpenTab(adapter)
        }
        controller?.didFocusWindow(windowAdapter)
        controller?.didChangeTabProperties([.title, .URL, .loading], for: adapter)
        postDidChange()
    }

    func unregister(panelID: UUID) {
        guard let adapter = tabAdaptersByPanelID.removeValue(forKey: panelID) else { return }
        actionPopupAnchorViewsByPanelID.removeValue(forKey: panelID)
        controller?.didCloseTab(adapter, windowIsClosing: false)
        postDidChange()
    }

    func installedExtensionSummaries() -> [BrowserWebExtensionInstalledSummary] {
        store.summaries(loadedRecordIDs: Set(contextsByRecordID.keys))
    }

    func actionSnapshots(for panel: BrowserPanel) -> [BrowserWebExtensionActionSnapshot] {
        guard let tab = tabAdaptersByPanelID[panel.id] else { return [] }
        return contextsByRecordID.compactMap { recordID, context in
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
        guard let context = contextsByRecordID[actionID] else {
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
        controller?.didChangeTabProperties([.title, .URL, .loading], for: tab)
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
        try await load(record: record)
        postDidChange()
        let summary = store.summaries(loadedRecordIDs: Set(contextsByRecordID.keys)).first { $0.id == record.id }
            ?? BrowserWebExtensionInstalledSummary(
                id: record.id,
                displayName: record.displayName,
                detail: browserWebExtensionSummaryDetail(
                    sourceKind: record.sourceKind,
                    displayVersion: record.displayVersion
                ),
                isEnabled: record.isEnabled,
                isLoaded: contextsByRecordID[record.id] != nil
            )
        return BrowserWebExtensionInstallResult(summary: summary, parseErrors: parseErrors)
    }

    func reloadInstalledExtensions() async {
        let controller = ensureController(defaultWebsiteDataStore: .default())
        closeAllActionPopups()
        closeAllAuxiliaryWindows()
        for context in contextsByRecordID.values {
            try? controller.unload(context)
        }
        contextsByRecordID.removeAll()
        store.reload()
        for record in store.records where record.isEnabled {
            try? await load(record: record)
        }
        postDidChange()
    }

    private func ensureController(defaultWebsiteDataStore: WKWebsiteDataStore) -> WKWebExtensionController {
        if let controller {
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
        self.controller = controller

        Task { @MainActor [weak self] in
            await self?.loadInstalledRecordsIfNeeded()
        }

        return controller
    }

    private func auxiliaryWebViewConfiguration(
        initialURL: URL?,
        context: WKWebExtensionContext,
        openerPanel: BrowserPanel?,
        shouldBePrivate: Bool
    ) -> WKWebViewConfiguration? {
        let configuration: WKWebViewConfiguration
        if let initialURL,
           let targetContext = controller?.extensionContext(for: initialURL),
           targetContext === context {
            guard let extensionConfiguration = context.webViewConfiguration else { return nil }
            configuration = extensionConfiguration
        } else {
            configuration = WKWebViewConfiguration()
            if let browserContext = openerPanel?.popupBrowserContext {
                BrowserPanel.configureWebViewConfiguration(
                    configuration,
                    websiteDataStore: browserContext.websiteDataStore,
                    processPool: browserContext.processPool
                )
            } else {
                BrowserPanel.configureWebViewConfiguration(
                    configuration,
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

    private func loadInstalledRecordsIfNeeded() async {
        guard !hasLoadedRecords else { return }
        hasLoadedRecords = true
        for record in store.records where record.isEnabled {
            try? await load(record: record)
        }
        postDidChange()
    }

    private func load(record: BrowserWebExtensionInstallRecord) async throws {
        let controller = ensureController(defaultWebsiteDataStore: .default())
        if let existing = contextsByRecordID[record.id] {
            try? controller.unload(existing)
            contextsByRecordID[record.id] = nil
        }

        let source = BrowserWebExtensionInstallSource(
            kind: record.sourceKind,
            url: URL(fileURLWithPath: record.sourcePath)
        )
        let webExtension = try await loadWebExtension(from: source)
        let context = WKWebExtensionContext(for: webExtension)
        if let uniqueIdentifier = browserWebExtensionContextUniqueIdentifier(for: record) {
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
        for rawPermission in browserWebExtensionHostGrantablePermissionNames(
            from: record.grantedPermissions,
            sourceKind: record.sourceKind
        ) {
            context.setPermissionStatus(
                .grantedExplicitly,
                for: WKWebExtension.Permission(rawPermission)
            )
        }
        for rawPattern in record.grantedPermissionMatchPatterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: rawPattern) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
        try controller.load(context)
        if webExtension.hasBackgroundContent {
            context.loadBackgroundContent { error in
#if DEBUG
                if let error {
                    cmuxDebugLog(
                        "browser.extensions.background.loadFailed label=\(record.displayName) error=\(error.localizedDescription)"
                    )
                }
#endif
            }
        }
        contextsByRecordID[record.id] = context
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
        let auxiliaryWindows = auxiliaryWindowAdaptersByID.values
            .filter(\.isVisible)
            .sorted { $0.createdAt < $1.createdAt }
        if let focusedAuxiliaryWindow = auxiliaryWindows.first(where: \.isKeyWindow) {
            return [focusedAuxiliaryWindow, windowAdapter] + auxiliaryWindows.filter { $0 !== focusedAuxiliaryWindow }
        }
        return [windowAdapter] + auxiliaryWindows
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        if let focusedAuxiliaryWindow = auxiliaryWindowAdaptersByID.values.first(where: \.isKeyWindow) {
            return focusedAuxiliaryWindow
        }
        return windowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        let opener = configuration.tabs.compactMap { ($0 as? BrowserWebExtensionTabAdapter)?.panel }.first
            ?? activeTabAdapter()?.panel
            ?? tabAdaptersByPanelID.values.compactMap(\.panel).first
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
        let opener = (configuration.parentTab as? BrowserWebExtensionTabAdapter)?.panel
            ?? activeTabAdapter()?.panel
            ?? tabAdaptersByPanelID.values.compactMap(\.panel).first
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
        controller?.didFocusWindow(window)
    }

    fileprivate func auxiliaryWindowDidChangeTabProperties(
        _ properties: WKWebExtension.TabChangedProperties,
        tab: BrowserWebExtensionAuxiliaryTabAdapter
    ) {
        controller?.didChangeTabProperties(properties, for: tab)
    }

    fileprivate func auxiliaryWindowDidClose(_ window: BrowserWebExtensionAuxiliaryWindowAdapter) {
        auxiliaryWindowAdaptersByID.removeValue(forKey: window.id)
        controller?.didCloseTab(window.tabAdapter, windowIsClosing: true)
        controller?.didCloseWindow(window)
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
        guard let recordID = contextsByRecordID.first(where: { $0.value === context })?.key,
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

    fileprivate func activeTabAdapter() -> BrowserWebExtensionTabAdapter? {
        if let focusedPanelID = AppDelegate.shared?.tabManager?.selectedWorkspace?.focusedPanelId,
           let adapter = tabAdaptersByPanelID[focusedPanelID] {
            return adapter
        }
        return tabAdaptersByPanelID.values.first { adapter in
            adapter.panel?.webView.window?.isKeyWindow == true
        }
    }

    fileprivate var tabAdapters: [BrowserWebExtensionTabAdapter] {
        var seenPanelIDs: Set<UUID> = []
        var orderedAdapters: [BrowserWebExtensionTabAdapter] = []

        if let tabManager = AppDelegate.shared?.tabManager {
            for workspace in tabManager.tabs {
                for panelID in workspace.sidebarOrderedPanelIds() where seenPanelIDs.insert(panelID).inserted {
                    if let adapter = tabAdaptersByPanelID[panelID] {
                        orderedAdapters.append(adapter)
                    }
                }
            }
        }

        let fallbackPanelIDs = tabAdaptersByPanelID.keys.sorted { $0.uuidString < $1.uuidString }
        for panelID in fallbackPanelIDs where seenPanelIDs.insert(panelID).inserted {
            if let adapter = tabAdaptersByPanelID[panelID] {
                orderedAdapters.append(adapter)
            }
        }
        return orderedAdapters
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionActionPopupPresentation: NSObject, NSPopoverDelegate {
    let id = UUID()
    private let popover = NSPopover()
    private let contentViewController = NSViewController()
    private let action: WKWebExtension.Action
    private let requestedContentSize: CGSize
    private let popupWebView: WKWebView
    private weak var runtime: BrowserWebExtensionRuntime?
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
        popover.behavior = .transient
        popover.animates = false
#if DEBUG
        popupWebView.isInspectable = true
#endif
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

    private func closeWebExtensionPopupIfNeeded() {
        guard !didClosePopup else { return }
        didClosePopup = true
        action.closePopup()
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionAuxiliaryWindowAdapter: NSObject, WKWebExtensionWindow, NSWindowDelegate {
    let id = UUID()
    let createdAt = Date()
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
        configuration: WKWebExtension.WindowConfiguration,
        webViewConfiguration: WKWebViewConfiguration,
        customUserAgent: String,
        initialURL: URL?,
        openerPanel: BrowserPanel?
    ) {
        self.runtime = runtime
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
        self.tabAdapter = BrowserWebExtensionAuxiliaryTabAdapter(webView: webView)

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
        if configuration.shouldBeFocused {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
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
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionAuxiliaryTabAdapter: NSObject, WKWebExtensionTab {
    weak var windowAdapter: BrowserWebExtensionAuxiliaryWindowAdapter?
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
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

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        runtimeTabAdapters()
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        runtime?.activeTabAdapter() ?? runtimeTabAdapters().first
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = runtime?.activeTabAdapter()?.panel?.webView.window ?? NSApp.keyWindow else {
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
        (runtime?.activeTabAdapter()?.panel?.webView.window ?? NSApp.keyWindow)?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (runtime?.activeTabAdapter()?.panel?.webView.window ?? NSApp.keyWindow)?.screen?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        runtime?.activeTabAdapter()?.panel?.focus()
        completionHandler(nil)
    }

    private func runtimeTabAdapters() -> [BrowserWebExtensionTabAdapter] {
        runtime?.tabAdapters ?? []
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var panel: BrowserPanel?
    private weak var windowAdapter: BrowserWebExtensionWindowAdapter?

    init(panel: BrowserPanel, windowAdapter: BrowserWebExtensionWindowAdapter) {
        self.panel = panel
        self.windowAdapter = windowAdapter
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
