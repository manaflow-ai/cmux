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

struct BrowserWebExtensionInstallResult: Equatable {
    let summary: BrowserWebExtensionInstalledSummary
    let parseErrors: [String]
}

struct BrowserWebExtensionInstallRecord: Codable, Equatable, Identifiable {
    enum SourceKind: String, Codable {
        case resourceBaseURL
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

enum BrowserWebExtensionInstallError: LocalizedError, Equatable {
    case unsupportedOS
    case cancelled
    case noManifest(URL)
    case noWebExtensionInApp(URL)
    case unsupportedSource(URL)
    case invalidChromeExtensionArchive(URL)
    case copyFailed(String)
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
                format: String(localized: "browser.extensions.error.unsupportedSource", defaultValue: "%@ is not an extension folder, ZIP, CRX, .appex, or app containing a Safari Web Extension."),
                url.lastPathComponent
            )
        case .invalidChromeExtensionArchive(let url):
            return String(
                format: String(localized: "browser.extensions.error.invalidChromeExtensionArchive", defaultValue: "%@ is not a valid Chrome extension package."),
                url.lastPathComponent
            )
        case .copyFailed(let message):
            return message
        case .loadFailed(let message):
            return message
        case .persistFailed(let message):
            return message
        }
    }
}

final class BrowserWebExtensionInstallStore {
    private let registryURL: URL
    private let installedResourceDirectoryURL: URL
    private let fileManager: FileManager

    private(set) var records: [BrowserWebExtensionInstallRecord] = []

    init(
        registryURL: URL = BrowserWebExtensionInstallStore.defaultRegistryURL(),
        installedResourceDirectoryURL: URL = BrowserWebExtensionInstallStore.defaultInstalledResourceDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.registryURL = registryURL
        self.installedResourceDirectoryURL = installedResourceDirectoryURL
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

    static func defaultInstalledResourceDirectoryURL() -> URL {
        defaultSupportDirectoryURL().appendingPathComponent("resources", isDirectory: true)
    }

    func reload() {
        guard let data = try? Data(contentsOf: registryURL),
              let decoded = try? JSONDecoder().decode([BrowserWebExtensionInstallRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    func summaries(loadedRecordIDs: Set<UUID> = []) -> [BrowserWebExtensionInstalledSummary] {
        records.map { record in
            let version = record.displayVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if let version, !version.isEmpty {
                detail = String(
                    format: String(localized: "browser.extensions.summary.version", defaultValue: "Version %@"),
                    version
                )
            } else {
                detail = record.sourceKind == .appExtensionBundle
                    ? String(localized: "browser.extensions.summary.appExtension", defaultValue: "App extension")
                    : String(localized: "browser.extensions.summary.localExtension", defaultValue: "Local extension")
            }
            return BrowserWebExtensionInstalledSummary(
                id: record.id,
                displayName: record.displayName,
                detail: detail,
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
        let recordID = existingRecordID(for: source) ?? UUID()
        let storedSourceURL: URL
        if source.kind == .resourceBaseURL {
            storedSourceURL = try copyResourceSource(source.url, recordID: recordID)
        } else {
            storedSourceURL = source.url
        }

        let record = BrowserWebExtensionInstallRecord(
            id: recordID,
            displayName: displayName,
            displayVersion: displayVersion,
            sourceKind: source.kind,
            sourcePath: storedSourceURL.path,
            isEnabled: true,
            grantedPermissions: grantedPermissions.sorted(),
            grantedPermissionMatchPatterns: grantedPermissionMatchPatterns.sorted()
        )

        if let index = records.firstIndex(where: { $0.id == recordID }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        try persist()
        return record
    }

    func setEnabled(_ isEnabled: Bool, for recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].isEnabled = isEnabled
        try persist()
    }

    func remove(recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let record = records.remove(at: index)
        if record.sourceKind == .resourceBaseURL {
            try? fileManager.removeItem(at: URL(fileURLWithPath: record.sourcePath).deletingLastPathComponent())
        }
        try persist()
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
            guard appExtensionHasManifest(resolvedURL) else {
                throw BrowserWebExtensionInstallError.noManifest(resolvedURL)
            }
            return BrowserWebExtensionInstallSource(kind: .appExtensionBundle, url: resolvedURL)
        }

        if pathExtension == "zip" || pathExtension == "crx" {
            return BrowserWebExtensionInstallSource(kind: .resourceBaseURL, url: resolvedURL)
        }

        if isDirectory(resolvedURL) {
            guard directoryHasManifest(resolvedURL) else {
                throw BrowserWebExtensionInstallError.noManifest(resolvedURL)
            }
            return BrowserWebExtensionInstallSource(kind: .resourceBaseURL, url: resolvedURL)
        }

        throw BrowserWebExtensionInstallError.unsupportedSource(resolvedURL)
    }

    func webKitLoadableSource(from source: BrowserWebExtensionInstallSource) throws -> BrowserWebExtensionInstallSource {
        guard source.kind == .resourceBaseURL,
              source.url.pathExtension.lowercased() == "crx" else {
            return source
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-browser-extension-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let zipURL = temporaryDirectory
            .appendingPathComponent(source.url.deletingPathExtension().lastPathComponent, isDirectory: false)
            .appendingPathExtension("zip")
        try Self.writeChromeExtensionZipPayload(from: source.url, to: zipURL)
        return BrowserWebExtensionInstallSource(kind: .resourceBaseURL, url: zipURL)
    }

    private func existingRecordID(for source: BrowserWebExtensionInstallSource) -> UUID? {
        guard source.kind == .appExtensionBundle else { return nil }
        return records.first { record in
            record.sourceKind == source.kind && URL(fileURLWithPath: record.sourcePath).standardizedFileURL == source.url.standardizedFileURL
        }?.id
    }

    private func copyResourceSource(_ sourceURL: URL, recordID: UUID) throws -> URL {
        do {
            try fileManager.createDirectory(at: installedResourceDirectoryURL, withIntermediateDirectories: true)
            let destinationDirectory = installedResourceDirectoryURL.appendingPathComponent(recordID.uuidString.lowercased(), isDirectory: true)
            if fileManager.fileExists(atPath: destinationDirectory.path) {
                try fileManager.removeItem(at: destinationDirectory)
            }
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destinationURL: URL
            if sourceURL.pathExtension.lowercased() == "crx" {
                destinationURL = destinationDirectory
                    .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent, isDirectory: false)
                    .appendingPathExtension("zip")
                try Self.writeChromeExtensionZipPayload(from: sourceURL, to: destinationURL)
            } else {
                destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: isDirectory(sourceURL))
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            return destinationURL
        } catch let installError as BrowserWebExtensionInstallError {
            throw installError
        } catch {
            throw BrowserWebExtensionInstallError.copyFailed(error.localizedDescription)
        }
    }

    private static func writeChromeExtensionZipPayload(from crxURL: URL, to destinationURL: URL) throws {
        let payload = try chromeExtensionZipPayload(from: crxURL)
        try payload.write(to: destinationURL, options: .atomic)
    }

    private static func chromeExtensionZipPayload(from crxURL: URL) throws -> Data {
        let data = try Data(contentsOf: crxURL)
        guard data.count >= 12,
              data[0] == 0x43,
              data[1] == 0x72,
              data[2] == 0x32,
              data[3] == 0x34 else {
            throw BrowserWebExtensionInstallError.invalidChromeExtensionArchive(crxURL)
        }

        let version = data.littleEndianUInt32(at: 4)
        let zipStart: Int
        switch version {
        case 2:
            guard data.count >= 16 else {
                throw BrowserWebExtensionInstallError.invalidChromeExtensionArchive(crxURL)
            }
            let publicKeyLength = Int(data.littleEndianUInt32(at: 8))
            let signatureLength = Int(data.littleEndianUInt32(at: 12))
            zipStart = 16 + publicKeyLength + signatureLength
        case 3:
            let headerLength = Int(data.littleEndianUInt32(at: 8))
            zipStart = 12 + headerLength
        default:
            throw BrowserWebExtensionInstallError.invalidChromeExtensionArchive(crxURL)
        }

        guard zipStart + 1 < data.count,
              data[zipStart] == 0x50,
              data[zipStart + 1] == 0x4b else {
            throw BrowserWebExtensionInstallError.invalidChromeExtensionArchive(crxURL)
        }

        return data.subdata(in: zipStart..<data.count)
    }

    private func persist() throws {
        do {
            try fileManager.createDirectory(
                at: registryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.cmuxBrowserExtensions.encode(records)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            throw BrowserWebExtensionInstallError.persistFailed(error.localizedDescription)
        }
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
        return children
            .filter { $0.pathExtension.lowercased() == "appex" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .first(where: appExtensionHasManifest)
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

    private func directoryHasManifest(_ directoryURL: URL) -> Bool {
        fileManager.fileExists(atPath: directoryURL.appendingPathComponent("manifest.json").path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private extension JSONEncoder {
    static var cmuxBrowserExtensions: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
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
private final class BrowserWebExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {
    static let shared = BrowserWebExtensionRuntime()

    private let store = BrowserWebExtensionInstallStore()
    private var controller: WKWebExtensionController?
    private var contextsByRecordID: [UUID: WKWebExtensionContext] = [:]
    private var tabAdaptersByPanelID: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var auxiliaryWindowAdaptersByID: [UUID: BrowserWebExtensionAuxiliaryWindowAdapter] = [:]
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
        guard let context = contextsByRecordID[actionID],
              let tab = tabAdaptersByPanelID[panel.id] else {
            return
        }
        context.performAction(for: tab)
    }

    func notePanelPropertiesChanged(panel: BrowserPanel) {
        guard let tab = tabAdaptersByPanelID[panel.id] else { return }
        controller?.didChangeTabProperties([.title, .URL, .loading], for: tab)
        postDidChange()
    }

    func installExtension(from url: URL) async throws -> BrowserWebExtensionInstallResult {
        let source = try store.discoverSource(from: url)
        let loadableSource = try store.webKitLoadableSource(from: source)
        defer {
            if loadableSource.url != source.url {
                try? FileManager.default.removeItem(at: loadableSource.url.deletingLastPathComponent())
            }
        }
        let webExtension = try await loadWebExtension(from: loadableSource)
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
        try await promptForInstallConsent(webExtension: webExtension)

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
                detail: record.displayVersion ?? "",
                isEnabled: record.isEnabled,
                isLoaded: contextsByRecordID[record.id] != nil
            )
        return BrowserWebExtensionInstallResult(summary: summary, parseErrors: parseErrors)
    }

    func reloadInstalledExtensions() async {
        let controller = ensureController(defaultWebsiteDataStore: .default())
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
        baseConfiguration.websiteDataStore = defaultWebsiteDataStore
        baseConfiguration.mediaTypesRequiringUserActionForPlayback = []
        baseConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true

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
        let usesExtensionOrigin: Bool
        if let initialURL,
           let targetContext = controller?.extensionContext(for: initialURL),
           targetContext === context {
            usesExtensionOrigin = true
        } else {
            usesExtensionOrigin = false
        }
        let configuration: WKWebViewConfiguration
        if usesExtensionOrigin {
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
        context.uniqueIdentifier = record.id.uuidString.lowercased()
        context.inspectionName = record.displayName
#if DEBUG
        context.isInspectable = true
#endif
        for rawPermission in record.grantedPermissions {
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
        contextsByRecordID[record.id] = context
    }

    private func loadWebExtension(from source: BrowserWebExtensionInstallSource) async throws -> WKWebExtension {
        do {
            switch source.kind {
            case .resourceBaseURL:
                return try await WKWebExtension(resourceBaseURL: source.url)
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

    private func promptForInstallConsent(webExtension: WKWebExtension) async throws {
        let alert = NSAlert()
        alert.messageText = String(localized: "browser.extensions.install.title", defaultValue: "Install Browser Extension?")
        alert.informativeText = installConsentMessage(webExtension)
        alert.addButton(withTitle: String(localized: "browser.extensions.install.confirm", defaultValue: "Install"))
        alert.addButton(withTitle: String(localized: "browser.extensions.install.cancel", defaultValue: "Cancel"))
        alert.alertStyle = .informational
        let response = await runModal(alert)
        guard response == .alertFirstButtonReturn else {
            throw BrowserWebExtensionInstallError.cancelled
        }
    }

    private func installConsentMessage(_ webExtension: WKWebExtension) -> String {
        let extensionName = webExtension.displayName
            ?? String(localized: "browser.extensions.unknownExtension", defaultValue: "Unknown extension")
        let permissions = webExtension.requestedPermissions
            .map { String($0.rawValue) }
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
                defaultValue: "%@\n\nAPI permissions: %@\nWebsite access: %@\n\ncmux grants only these permissions and lets WebKit enforce extension isolation, host access, and runtime permission prompts."
            ),
            extensionName,
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

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let message = permissions.map { String($0.rawValue) }.sorted().joined(separator: ", ")
        promptForRuntimePermission(message: message) { allowed in
            completionHandler(allowed ? permissions : [], nil)
        }
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
        guard let popover = action.popupPopover,
              let anchorView = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel?.webView
                ?? activeTabAdapter()?.panel?.webView else {
            completionHandler(nil)
            return
        }
        let rect = NSRect(x: max(anchorView.bounds.maxX - 1, 0), y: anchorView.bounds.maxY, width: 1, height: 1)
        popover.show(relativeTo: rect, of: anchorView, preferredEdge: .maxY)
        completionHandler(nil)
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
        Array(tabAdaptersByPanelID.values)
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
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
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
        runtime?.tabAdapters.sorted {
            ($0.panel?.displayTitle ?? "").localizedCaseInsensitiveCompare($1.panel?.displayTitle ?? "") == .orderedAscending
        } ?? []
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
