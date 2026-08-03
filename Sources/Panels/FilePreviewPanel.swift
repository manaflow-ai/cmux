import CmuxFoundation
import AppKit
import AVKit
import Bonsplit
import Combine
import Foundation
import Observation
import PDFKit
import Quartz
import UniformTypeIdentifiers

enum FilePreviewInteraction {
    static let zoomStep: CGFloat = 1.25

    static func hasZoomModifier(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.option) || flags.contains(.command)
    }

    static func zoomFactor(forScroll event: NSEvent) -> CGFloat {
        let rawDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        let normalizedDelta = event.hasPreciseScrollingDeltas ? rawDelta : rawDelta * 8
        let factor = pow(1.0025, normalizedDelta)
        guard factor.isFinite else { return 1 }
        return min(max(factor, 0.2), 5.0)
    }

}

struct FileExternalOpenApplication: Identifiable, Equatable, Sendable {
    let url: URL
    let displayName: String
    let isDefault: Bool

    var id: String {
        FileExternalOpenApplicationResolver.applicationIdentity(for: url)
    }
}

struct FileExternalOpenApplicationResolver: Sendable {
    var defaultApplicationURL: @Sendable (URL) -> URL?
    var applicationURLs: @Sendable (URL) -> [URL]
    var displayName: @Sendable (URL) -> String
    var shouldIncludeApplication: @Sendable (URL) -> Bool

    static let live = FileExternalOpenApplicationResolver(
        defaultApplicationURL: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        applicationURLs: { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
        displayName: { Self.liveDisplayName(for: $0) },
        shouldIncludeApplication: { Self.shouldIncludeLiveApplication($0) }
    )

    func applications(for fileURL: URL) -> [FileExternalOpenApplication] {
        let defaultURL = defaultApplicationURL(fileURL).flatMap { url in
            shouldIncludeApplication(url) ? url : nil
        }
        let defaultIdentity = defaultURL.map(Self.applicationIdentity(for:))
        var orderedURLs = defaultURL.map { [$0] } ?? []
        orderedURLs.append(contentsOf: applicationURLs(fileURL).filter(shouldIncludeApplication))

        var seenIdentities: Set<String> = []
        return orderedURLs.compactMap { applicationURL in
            let identity = Self.applicationIdentity(for: applicationURL)
            guard seenIdentities.insert(identity).inserted else { return nil }
            return FileExternalOpenApplication(
                url: applicationURL,
                displayName: displayName(applicationURL),
                isDefault: identity == defaultIdentity
            )
        }
    }

    static func applicationIdentity(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func liveDisplayName(for applicationURL: URL) -> String {
        let bundle = Bundle(url: applicationURL)
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        var name = bundleName ?? FileManager.default.displayName(atPath: applicationURL.path)
        if name.lowercased().hasSuffix(".app") {
            name = String(name.dropLast(4))
        }
        return name.isEmpty ? applicationURL.deletingPathExtension().lastPathComponent : name
    }

    private static func shouldIncludeLiveApplication(_ applicationURL: URL) -> Bool {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier?.lowercased() else {
            return true
        }
        if Bundle.main.bundleIdentifier?.lowercased() == bundleIdentifier {
            return false
        }
        return !bundleIdentifier.hasPrefix("dev.cmux.")
            && !bundleIdentifier.hasPrefix("com.cmuxterm.")
    }
}

enum FileExternalOpenAction {
    @discardableResult
    static func openDefault(fileURL: URL) -> Bool {
        let resolver = FileExternalOpenApplicationResolver.live
        guard let defaultURL = resolver.defaultApplicationURL(fileURL) else {
            return open(fileURL: fileURL, applicationURL: nil)
        }
        if resolver.shouldIncludeApplication(defaultURL) {
            return open(fileURL: fileURL, applicationURL: defaultURL)
        }
        let fallbackURL = resolver.applicationURLs(fileURL).first(where: resolver.shouldIncludeApplication)
        guard let fallbackURL else { return false }
        return open(fileURL: fileURL, applicationURL: fallbackURL)
    }

    @discardableResult
    static func open(fileURL: URL, applicationURL: URL?) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        if let applicationURL {
            NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
        return NSWorkspace.shared.open(fileURL)
    }

    static func revealInFinder(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

enum FileExternalOpenText {
    static var openWithMenu: String {
        String(localized: "filePreview.openWith.menu", defaultValue: "Open With")
    }

    static var openExternally: String {
        String(localized: "filePreview.openExternally", defaultValue: "Open Externally")
    }

    static func openInApplication(_ applicationName: String) -> String {
        let format = String(localized: "filePreview.openInApplication", defaultValue: "Open in %@")
        return String(format: format, applicationName)
    }

    static var revealInFinder: String {
        String(localized: "fileExplorer.contextMenu.revealInFinder", defaultValue: "Reveal in Finder")
    }
}

enum FileExternalOpenMenuFactory {
    static func makeMenu(
        fileURL: URL,
        primaryApplication: FileExternalOpenApplication?,
        otherApplications: [FileExternalOpenApplication]
    ) -> NSMenu {
        let menu = NSMenu(title: FileExternalOpenText.openWithMenu)
        menu.autoenablesItems = false

        if let primaryApplication {
            menu.addItem(menuItem(
                title: FileExternalOpenText.openInApplication(primaryApplication.displayName),
                fileURL: fileURL,
                action: .open(applicationURL: primaryApplication.url)
            ))
        } else {
            menu.addItem(menuItem(
                title: FileExternalOpenText.openExternally,
                fileURL: fileURL,
                action: .open(applicationURL: nil)
            ))
        }

        menu.addItem(menuItem(
            title: FileExternalOpenText.revealInFinder,
            fileURL: fileURL,
            action: .revealInFinder
        ))

        if !otherApplications.isEmpty {
            menu.addItem(.separator())
            let openWithMenu = NSMenu(title: FileExternalOpenText.openWithMenu)
            openWithMenu.autoenablesItems = false
            for application in otherApplications {
                openWithMenu.addItem(menuItem(
                    title: application.displayName,
                    fileURL: fileURL,
                    action: .open(applicationURL: application.url)
                ))
            }
            let openWithItem = NSMenuItem(
                title: FileExternalOpenText.openWithMenu,
                action: nil,
                keyEquivalent: ""
            )
            openWithItem.submenu = openWithMenu
            menu.addItem(openWithItem)
        }

        return menu
    }

    private static func menuItem(
        title: String,
        fileURL: URL,
        action: FileExternalOpenMenuPayloadAction
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(FileExternalOpenMenuActionTarget.open(_:)),
            keyEquivalent: ""
        )
        item.target = FileExternalOpenMenuActionTarget.shared
        item.representedObject = FileExternalOpenMenuActionPayload(
            fileURL: fileURL,
            action: action
        )
        return item
    }
}

private enum FileExternalOpenMenuPayloadAction {
    case open(applicationURL: URL?)
    case revealInFinder
}

private final class FileExternalOpenMenuActionPayload: NSObject {
    let fileURL: URL
    let action: FileExternalOpenMenuPayloadAction

    init(fileURL: URL, action: FileExternalOpenMenuPayloadAction) {
        self.fileURL = fileURL
        self.action = action
    }
}

private final class FileExternalOpenMenuActionTarget: NSObject {
    static let shared = FileExternalOpenMenuActionTarget()

    @objc func open(_ item: NSMenuItem) {
        guard let payload = item.representedObject as? FileExternalOpenMenuActionPayload else {
            return
        }
        switch payload.action {
        case .open(let applicationURL):
            guard let applicationURL else {
                FileExternalOpenAction.openDefault(fileURL: payload.fileURL)
                return
            }
            FileExternalOpenAction.open(fileURL: payload.fileURL, applicationURL: applicationURL)
        case .revealInFinder:
            FileExternalOpenAction.revealInFinder(fileURL: payload.fileURL)
        }
    }
}

struct FilePreviewDragEntry {
    let filePath: String
    let displayTitle: String
}

final class FilePreviewDragRegistry {
    static let shared = FilePreviewDragRegistry()

    private let lock = NSLock()
    private var pending: [UUID: PendingEntry] = [:]
    private static let entryTTL: TimeInterval = 60

    private struct PendingEntry {
        let entry: FilePreviewDragEntry
        let registeredAt: Date
    }

    func register(_ entry: FilePreviewDragEntry, id: UUID = UUID(), now: Date = Date()) -> UUID {
        lock.lock()
        sweepExpiredLocked(now: now)
        pending[id] = PendingEntry(entry: entry, registeredAt: now)
        lock.unlock()
        return id
    }

    func consume(id: UUID, now: Date = Date()) -> FilePreviewDragEntry? {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending.removeValue(forKey: id)?.entry
    }

    func contains(id: UUID, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending[id] != nil
    }

    func entry(id: UUID, now: Date = Date()) -> FilePreviewDragEntry? {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending[id]?.entry
    }

    func discard(id: UUID) {
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
    }

    func discardExpired(now: Date = Date()) {
        lock.lock()
        sweepExpiredLocked(now: now)
        lock.unlock()
    }

    func discardAll() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    private func sweepExpiredLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.entryTTL)
        pending = pending.filter { _, value in
            value.registeredAt >= cutoff
        }
    }
}

final class FilePreviewDragPasteboardWriter: NSObject, NSPasteboardWriting {
    private struct MirrorTabItem: Codable {
        let id: UUID
        let title: String
        let hasCustomTitle: Bool
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isDirty: Bool
        let showsNotificationBadge: Bool
        let isLoading: Bool
        let isPinned: Bool
    }

    private struct MirrorTabTransferData: Codable {
        let tab: MirrorTabItem
        let sourcePaneId: UUID
        let sourceProcessId: Int32
    }

    static let bonsplitTransferType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")

    private let filePath: String
    private let displayTitle: String
    private var transferData: Data?
    private var didMirrorTransferDataToDragPasteboard = false

    init(filePath: String, displayTitle: String) {
        self.filePath = filePath
        self.displayTitle = displayTitle
        super.init()
    }

    static func dragID(from transferData: Data) -> UUID? {
        guard let transfer = try? JSONDecoder().decode(MirrorTabTransferData.self, from: transferData) else {
            return nil
        }
        return transfer.tab.id
    }

    static func dragID(from pasteboard: NSPasteboard) -> UUID? {
        for type in [DragOverlayRoutingPolicy.filePreviewTransferType, Self.bonsplitTransferType] {
            if let data = pasteboard.data(forType: type),
               let id = dragID(from: data) {
                return id
            }
            if let raw = pasteboard.string(forType: type),
               let id = dragID(from: Data(raw.utf8)) {
                return id
            }
        }
        return nil
    }

    static func discardRegisteredDrag(from pasteboard: NSPasteboard) {
        if let id = dragID(from: pasteboard) {
            FilePreviewDragRegistry.shared.discard(id: id)
        }
        FilePreviewDragRegistry.shared.discardExpired()
    }

    private func transferDataForDrag() -> Data {
        if let transferData {
            return transferData
        }

        let dragId = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: filePath, displayTitle: displayTitle)
        )
        let transfer = MirrorTabTransferData(
            tab: MirrorTabItem(
                id: dragId,
                title: displayTitle,
                hasCustomTitle: false,
                icon: FilePreviewKindResolver.initialTabIconName(for: URL(fileURLWithPath: filePath)),
                iconImageData: nil,
                kind: "filePreview",
                isDirty: false,
                showsNotificationBadge: false,
                isLoading: false,
                isPinned: false
            ),
            sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        let data = (try? JSONEncoder().encode(transfer)) ?? Data()
        transferData = data
        return data
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let data = transferDataForDrag()
        mirrorTransferDataToDragPasteboard(data)
        return [
            DragOverlayRoutingPolicy.filePreviewTransferType,
            Self.bonsplitTransferType,
            .fileURL
        ]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.bonsplitTransferType || type == DragOverlayRoutingPolicy.filePreviewTransferType {
            let data = transferDataForDrag()
            mirrorTransferDataToDragPasteboard(data)
            return data
        }
        if type == .fileURL {
            let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
            return fileURL.absoluteString
        }
        return nil
    }

    private func mirrorTransferDataToDragPasteboard(_ transferData: Data) {
        guard !didMirrorTransferDataToDragPasteboard else { return }
        didMirrorTransferDataToDragPasteboard = true
        let fileURLString = URL(fileURLWithPath: filePath).standardizedFileURL.absoluteString
        let write = { [transferData, fileURLString] in
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.addTypes([DragOverlayRoutingPolicy.filePreviewTransferType, Self.bonsplitTransferType, .fileURL], owner: nil)
            pasteboard.setData(transferData, forType: Self.bonsplitTransferType)
            pasteboard.setData(transferData, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
            pasteboard.setString(fileURLString, forType: .fileURL)
        }
        if Thread.isMainThread {
            write()
        } else {
            DispatchQueue.main.async(execute: write)
        }
    }
}

enum FilePreviewMode: Equatable {
    case text
    case pdf
    case image
    case media
    case quickLook
}

enum FilePreviewKindResolver {
    enum Resolution: Sendable {
        case resolved(FilePreviewMode)
        case needsSniff
    }

    private static let textFilenames: Set<String> = [
        ".env",
        ".gitignore",
        ".gitattributes",
        ".npmrc",
        ".zshrc",
        "dockerfile",
        "makefile",
        "gemfile",
        "podfile"
    ]

    private static let textExtensions: Set<String> = [
        "bash", "c", "cc", "cfg", "conf", "cpp", "cs", "css", "csv", "cts", "env",
        "fish", "go", "h", "hpp", "htm", "html", "ini", "java", "js", "json",
        "jsx", "kt", "log", "m", "markdown", "md", "mdx", "mm", "mts", "plist",
        "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "tsv", "txt",
        "xml", "yaml", "yml", "zsh"
    ]

    static func mode(for url: URL) -> FilePreviewMode {
        switch resolvedResolution(for: url) {
        case .resolved(let mode):
            return mode
        case .needsSniff:
            return sniffLooksLikeText(url: url) ? .text : .quickLook
        }
    }

    static func initialMode(for url: URL) -> FilePreviewMode {
        switch initialResolution(for: url) {
        case .resolved(let mode):
            return mode
        case .needsSniff:
            return .quickLook
        }
    }

    @concurrent
    static func resolveMode(url: URL) async -> FilePreviewMode {
        mode(for: url)
    }

    static func tabIconName(for url: URL) -> String {
        iconName(for: mode(for: url))
    }

    static func initialTabIconName(for url: URL) -> String {
        iconName(for: initialMode(for: url))
    }

    static func iconName(for mode: FilePreviewMode) -> String {
        switch mode {
        case .text:
            return "doc.text"
        case .pdf:
            return "doc.richtext"
        case .image:
            return "photo"
        case .media:
            return "play.rectangle"
        case .quickLook:
            return "doc.viewfinder"
        }
    }

    private static func initialResolution(for url: URL) -> Resolution {
        let ext = url.pathExtension.lowercased()
        if let textResolution = knownTextResolutionBeforeMedia(for: url, sniffMediaCollisions: false) {
            return textResolution
        }

        if let type = UTType(filenameExtension: ext),
           let mediaMode = mediaMode(for: type) {
            return .resolved(mediaMode)
        }

        if ext == "plist" {
            return .needsSniff
        }

        if knownTextFile(url: url, includeResourceContentType: false) {
            return .resolved(.text)
        }

        return .needsSniff
    }

    private static func resolvedResolution(for url: URL) -> Resolution {
        let ext = url.pathExtension.lowercased()
        if ext == "plist", looksLikeBinaryPropertyList(url: url) {
            return .resolved(.quickLook)
        }

        if let textResolution = knownTextResolutionBeforeMedia(for: url, sniffMediaCollisions: true) {
            return textResolution
        }

        for type in contentTypes(for: url) {
            if let mediaMode = mediaMode(for: type) {
                return .resolved(mediaMode)
            }
        }

        if knownTextFile(url: url, includeResourceContentType: true) {
            return .resolved(.text)
        }

        return .needsSniff
    }

    private static func mediaMode(for type: UTType) -> FilePreviewMode? {
        if type.conforms(to: .pdf) {
            return .pdf
        }
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .movie)
            || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .audio) {
            return .media
        }
        return nil
    }

    private static func contentTypes(for url: URL) -> [UTType] {
        var types: [UTType] = []
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type != .data {
            types.append(type)
        }
        if let fallbackType = UTType(filenameExtension: url.pathExtension.lowercased()),
           !types.contains(fallbackType) {
            types.append(fallbackType)
        }
        return types
    }

    private static func knownTextFile(url: URL, includeResourceContentType: Bool) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if textFilenames.contains(filename) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) {
            return true
        }
        if includeResourceContentType,
           let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            return true
        }
        if let type = UTType(filenameExtension: ext),
           type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            return true
        }
        return false
    }

    private static func knownTextResolutionBeforeMedia(for url: URL, sniffMediaCollisions: Bool) -> Resolution? {
        let filename = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        guard ext != "plist",
              textFilenames.contains(filename) || textExtensions.contains(ext) else {
            return nil
        }

        guard let type = UTType(filenameExtension: ext),
              let mediaMode = mediaMode(for: type),
              !type.conforms(to: .text),
              !type.conforms(to: .sourceCode) else {
            return .resolved(.text)
        }

        // Source extensions can collide with system audio/video UTIs (.ts, .mts).
        // Initial routing stays extension-only; resolved routing sniffs off-main.
        guard sniffMediaCollisions else {
            return .resolved(.text)
        }
        if sniffLooksLikeText(url: url) {
            return .resolved(.text)
        }
        if looksLikeMPEGTransportStream(url: url) {
            return .resolved(.media)
        }
        return .resolved(mediaMode)
    }

    private static func looksLikeBinaryPropertyList(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8)) ?? Data()
        return String(data: data, encoding: .ascii) == "bplist00"
    }

    private static func looksLikeMPEGTransportStream(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard data.count >= 376 else { return false }

        let syncCandidates = [
            (packetSize: 188, syncOffset: 0),
            (packetSize: 192, syncOffset: 0),
            (packetSize: 192, syncOffset: 4),
            (packetSize: 204, syncOffset: 0)
        ]

        for candidate in syncCandidates where data.count > candidate.syncOffset {
            var offset = candidate.syncOffset
            var syncCount = 0
            while offset < data.count {
                guard data[offset] == 0x47 else { break }
                syncCount += 1
                offset += candidate.packetSize
            }
            if syncCount >= 2 {
                return true
            }
        }

        return false
    }

    private static func sniffLooksLikeText(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !data.isEmpty else { return true }
        if hasUTF16ByteOrderMark(data), String(data: data, encoding: .utf16) != nil {
            return true
        }
        if data.contains(0) {
            return false
        }
        return String(data: data, encoding: .utf8) != nil
    }

    private static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        data.count >= 2 && (
            (data[0] == 0xFF && data[1] == 0xFE)
                || (data[0] == 0xFE && data[1] == 0xFF)
        )
    }
}

enum FilePreviewTextLoader {
    static let maximumLoadedTextBytes: UInt64 = 16 * 1024 * 1024

    enum Result: Sendable {
        case loaded(content: String, encoding: String.Encoding)
        case unavailable
    }

    @concurrent
    static func load(url: URL) async -> Result {
        loadSynchronously(url: url)
    }

    static func loadSynchronously(url: URL) -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable
        }
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize >= 0,
              UInt64(fileSize) <= maximumLoadedTextBytes else {
            return .unavailable
        }

        do {
            let data = try Data(contentsOf: url)
            guard let decoded = decodeText(data) else {
                return .unavailable
            }
            return .loaded(content: decoded.content, encoding: decoded.encoding)
        } catch {
            return .unavailable
        }
    }

    private static func decodeText(_ data: Data) -> (content: String, encoding: String.Encoding)? {
        if let decoded = String(data: data, encoding: .utf8) {
            return (decoded, .utf8)
        }
        if let decoded = String(data: data, encoding: .utf16) {
            return (decoded, .utf16)
        }
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return (decoded, .isoLatin1)
        }
        return nil
    }
}

enum FilePreviewTextSaver {
    enum Result: Sendable {
        case saved
        case failed(fileExists: Bool)
    }

    @concurrent
    static func save(content: String, to url: URL, encoding: String.Encoding) async -> Result {
        guard let data = content.data(using: encoding) else {
            return .failed(fileExists: FileManager.default.fileExists(atPath: url.path))
        }

        do {
            try data.write(to: url, options: [])
            return .saved
        } catch {
            return .failed(fileExists: FileManager.default.fileExists(atPath: url.path))
        }
    }
}

@MainActor
final class FilePreviewPanel: Panel, ObservableObject, FilePreviewTextEditingPanel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .filePreview
    let filePath: String
    private(set) var workspaceId: UUID
    @Published private(set) var displayTitle: String
    @Published private(set) var displayIcon: String?
    @Published private(set) var isFileUnavailable = false
    @Published private(set) var textContent = ""
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var focusFlashToken = 0
    @Published private(set) var previewMode: FilePreviewMode
    let previewRevisionState = FilePreviewRevision()

    let nativeViewSessions = FilePreviewNativeViewSessions()

    private var originalTextContent = ""
    private var textEncoding: String.Encoding = .utf8
    private var saveGeneration = 0
    private var activeSaveGeneration: Int?
    var fileChangeWatcher: FileWatcher?
    var fileChangeTask: Task<Void, Never>?
    var fileChangeReloadTask: Task<Void, Never>?
    var lastObservedFileState: FilePreviewFileState?
    var isClosed = false
    weak var textView: NSTextView?
    let focusCoordinator: FilePreviewFocusCoordinator
    private let textLoader: @Sendable (URL) async -> FilePreviewTextLoader.Result
    private let textSaver: @Sendable (String, URL, String.Encoding) async -> FilePreviewTextSaver.Result
    private let modeResolver: @Sendable (URL) async -> FilePreviewMode
    private let textLoadCoordinator = FilePreviewLatestLoadCoordinator<FilePreviewTextLoader.Result>()
    private let modeLoadCoordinator = FilePreviewLatestLoadCoordinator<FilePreviewMode>()

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var previewRevision: Int {
        previewRevisionState.value
    }

    init(
        workspaceId: UUID,
        filePath: String,
        startFileWatcher: Bool = true,
        textLoader: @escaping @Sendable (URL) async -> FilePreviewTextLoader.Result = { url in
            await FilePreviewTextLoader.load(url: url)
        },
        textSaver: @escaping @Sendable (String, URL, String.Encoding) async -> FilePreviewTextSaver.Result = {
            content, url, encoding in
            await FilePreviewTextSaver.save(content: content, to: url, encoding: encoding)
        },
        modeResolver: @escaping @Sendable (URL) async -> FilePreviewMode = { url in
            await FilePreviewKindResolver.resolveMode(url: url)
        }
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = URL(fileURLWithPath: filePath).lastPathComponent
        self.textLoader = textLoader
        self.textSaver = textSaver
        self.modeResolver = modeResolver
        let fileURL = URL(fileURLWithPath: filePath)
        let initialPreviewMode = FilePreviewKindResolver.initialMode(for: fileURL)
        self.previewMode = initialPreviewMode
        self.displayIcon = FilePreviewKindResolver.iconName(for: initialPreviewMode)
        self.focusCoordinator = FilePreviewFocusCoordinator(
            preferredIntent: Self.defaultFocusIntent(for: initialPreviewMode)
        )
        self.lastObservedFileState = .capture(path: filePath)

        prepareContentForPreviewMode()
        resolvePreviewModeIfNeeded(for: fileURL)
        if startFileWatcher {
            startWatchingForFileChanges()
        }
    }

    func focus() {
        _ = restoreFocusIntent(preferredFocusIntentForActivation())
    }

    func unfocus() {
        // No-op. AppKit resigns the text view when another panel becomes first responder.
    }

    func close() {
        isClosed = true
        stopWatchingForFileChanges()
        textLoadCoordinator.cancel()
        modeLoadCoordinator.cancel()
        nativeViewSessions.closeAll()
        textView = nil
        focusCoordinator.unregisterAll()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func handleDroppedFileURLsAsText(_ urls: [URL]) -> Bool {
        guard previewMode == .text, let textView else { return false }
        let text = TerminalImageTransferPlanner.insertedText(forFileURLs: urls)
        guard !text.isEmpty else { return false }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
        updateTextContent(textView.string)
        return true
    }

    func retryPendingFocus() {
        focusCoordinator.fulfillPendingFocusIfNeeded()
    }

    func attachPDFPreview(root: NSView, primaryResponder: NSView) {
        attachPreviewFocus(root: root, primaryResponder: primaryResponder, intent: .pdfCanvas)
    }

    func attachPreviewFocus(
        root: NSView,
        primaryResponder: NSView,
        intent: FilePreviewPanelFocusIntent
    ) {
        focusCoordinator.register(root: root, primaryResponder: primaryResponder, intent: intent)
    }

    func noteFilePreviewFocusIntent(_ intent: FilePreviewPanelFocusIntent) {
        focusCoordinator.notePreferredIntent(intent)
    }

    func currentFilePreviewFocusIntent(in window: NSWindow?) -> FilePreviewPanelFocusIntent? {
        guard let window,
              let responder = window.firstResponder else { return nil }
        return focusCoordinator.ownedIntent(for: responder, in: window)
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        if let window,
           let responder = window.firstResponder,
           let intent = ownedFocusIntent(for: responder, in: window) {
            return intent
        }
        return preferredFocusIntentForActivation()
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .filePreview(focusCoordinator.preferredIntent)
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        if case .filePreview(let filePreviewIntent) = intent {
            focusCoordinator.notePreferredIntent(filePreviewIntent)
        }
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        let filePreviewIntent: FilePreviewPanelFocusIntent
        switch intent {
        case .filePreview(let target):
            filePreviewIntent = target
        case .panel:
            filePreviewIntent = focusCoordinator.preferredIntent
        case .terminal, .browser, .project:
            return false
        }
        return focusCoordinator.focus(filePreviewIntent)
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        if let intent = focusCoordinator.ownedIntent(for: responder, in: window) {
            return .filePreview(intent)
        }
        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder,
              ownedFocusIntent(for: responder, in: window) == intent else {
            return false
        }
        return window.makeFirstResponder(nil)
    }

    func updateTextContent(_ nextContent: String) {
        guard textContent != nextContent else { return }
        textContent = nextContent
        isDirty = nextContent != originalTextContent
    }

    /// Re-resolves and reloads the current path. Toolbar actions and filesystem
    /// events share this path so every renderer observes the same revision.
    @discardableResult
    func reloadFromDisk() -> Task<Void, Never> {
        lastObservedFileState = .capture(path: filePath)
        let fileURL = fileURL
        let modeResolver = modeResolver

        return modeLoadCoordinator.submit(load: {
            await modeResolver(fileURL)
        }) { [weak self] resolvedMode in
            guard let self, !self.isClosed else { return }

            if resolvedMode != self.previewMode {
                if self.previewMode == .text, self.isDirty {
                    await self.loadTextContent(replacingDirtyContent: false).value
                    return
                }
                await self.applyResolvedPreviewMode(resolvedMode)?.value
                return
            }

            if resolvedMode == .text {
                await self.loadTextContent(replacingDirtyContent: false).value
            } else {
                self.isFileUnavailable = !FileManager.default.fileExists(atPath: self.filePath)
                if self.isFileUnavailable {
                    if self.previewMode == .media {
                        self.nativeViewSessions.media.close()
                    }
                } else {
                    self.previewRevisionState.increment()
                }
            }
        }
    }

    @discardableResult
    private func prepareContentForPreviewMode() -> Task<Void, Never>? {
        if previewMode == .text {
            return loadTextContent(replacingDirtyContent: false)
        } else {
            isFileUnavailable = !FileManager.default.fileExists(atPath: filePath)
            return nil
        }
    }

    private func resolvePreviewModeIfNeeded(for fileURL: URL) {
        let initialMode = previewMode
        let initialIcon = displayIcon
        let modeResolver = modeResolver

        modeLoadCoordinator.submit(load: {
            await modeResolver(fileURL)
        }) { [weak self] resolvedMode in
            guard let self else { return }
            let resolvedIcon = FilePreviewKindResolver.iconName(for: resolvedMode)
            guard resolvedMode != initialMode || resolvedIcon != initialIcon else { return }
            await self.applyResolvedPreviewMode(resolvedMode)?.value
        }
    }

    @discardableResult
    private func applyResolvedPreviewMode(_ mode: FilePreviewMode) -> Task<Void, Never>? {
        guard previewMode != mode else { return nil }
        if mode != .text {
            textLoadCoordinator.cancel()
        }
        previewMode = mode
        displayIcon = FilePreviewKindResolver.iconName(for: mode)
        focusCoordinator.notePreferredIntent(Self.defaultFocusIntent(for: mode))
        nativeViewSessions.closeInactive(except: mode)
        return prepareContentForPreviewMode()
    }

    @discardableResult
    func loadTextContent(replacingDirtyContent: Bool = true) -> Task<Void, Never> {
        guard previewMode == .text else {
            return Task {}
        }
        let fileURL = fileURL
        let textLoader = textLoader

        return textLoadCoordinator.submit(load: {
            await textLoader(fileURL)
        }) { [weak self] result in
            guard let self, self.previewMode == .text else { return }
            self.applyTextLoadResult(result, replacingDirtyContent: replacingDirtyContent)
        }
    }

    private func applyTextLoadResult(
        _ result: FilePreviewTextLoader.Result,
        replacingDirtyContent: Bool
    ) {
        switch result {
        case .unavailable:
            guard replacingDirtyContent || !isDirty else {
                isFileUnavailable = true
                return
            }
            textContent = ""
            originalTextContent = ""
            isDirty = false
            isFileUnavailable = true
            return
        case .loaded(let content, let encoding):
            if !replacingDirtyContent && isDirty {
                originalTextContent = content
                textEncoding = encoding
                isDirty = textContent != originalTextContent
                isFileUnavailable = false
                return
            }
            textContent = content
            originalTextContent = content
            textEncoding = encoding
            isDirty = false
            isFileUnavailable = false
        }
    }

    @discardableResult
    func saveTextContent() -> Task<Void, Never>? {
        guard previewMode == .text else { return nil }
        guard !isSaving else { return nil }
        let currentContent = textView?.string ?? textContent
        guard currentContent != originalTextContent else {
            textContent = currentContent
            isDirty = false
            return nil
        }

        textLoadCoordinator.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        textContent = currentContent
        isSaving = true
        activeSaveGeneration = generation
        let fileURL = fileURL
        let encoding = textEncoding
        let textSaver = textSaver
        return Task { [weak self, currentContent, fileURL, encoding, generation, textSaver] in
            let result = await textSaver(currentContent, fileURL, encoding)
            guard let self, self.activeSaveGeneration == generation else { return }
            self.activeSaveGeneration = nil
            self.isSaving = false
            let reconciliationTask: Task<Void, Never>?
            switch result {
            case .saved:
                self.originalTextContent = currentContent
                self.isDirty = self.textContent != currentContent
                self.isFileUnavailable = false
                reconciliationTask = self.reloadFromDisk()
            case .failed(let fileExists):
                self.isFileUnavailable = !fileExists
                reconciliationTask = self.handleObservedFileChange()
            }
            await reconciliationTask?.value
        }
    }

    private static func defaultFocusIntent(for mode: FilePreviewMode) -> FilePreviewPanelFocusIntent {
        switch mode {
        case .text:
            return .textEditor
        case .pdf:
            return .pdfCanvas
        case .image:
            return .imageCanvas
        case .media:
            return .mediaPlayer
        case .quickLook:
            return .quickLook
        }
    }
}

@MainActor
final class FilePreviewPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private enum InstalledContent: Equatable {
        case unavailable
        case preview(FilePreviewMode)
    }

    private var configuration: PanelContentConfiguration
    private weak var panel: FilePreviewPanel?
    private var panelCancellable: AnyCancellable?
    private var defaultsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var externalApplicationTask: Task<Void, Never>?
    private var externalApplications: [FileExternalOpenApplication] = []
    private var lastFocusFlashToken = 0
    private var revisionObservationGeneration = 0

    private let header = FilePreviewPanelHeaderNativeView()
    private let divider = NSBox()
    private let contentContainer = NSView()
    private let unavailableView = PanelFileUnavailableNativeView(
        title: String(localized: "filePreview.fileUnavailable.title", defaultValue: "File unavailable"),
        message: String(
            localized: "filePreview.fileUnavailable.message",
            defaultValue: "The file may have been moved or deleted."
        )
    )
    private let pointerObserver = FilePreviewPointerObserverView()
    private let flashRing = WorkspaceAttentionFlashRingNativeView(frame: .zero)
    private var headerHeightConstraint: NSLayoutConstraint?
    private var dividerHeightConstraint: NSLayoutConstraint?
    private var installedContent: InstalledContent?
    private weak var installedView: NSView?
    private var textEditorController: FilePreviewTextEditorController?

    init(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        contentContainer.wantsLayer = true
        divider.boxType = .separator
        [header, divider, contentContainer, pointerObserver, flashRing].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 30)
        let dividerHeight = divider.heightAnchor.constraint(equalToConstant: 1)
        headerHeightConstraint = headerHeight
        dividerHeightConstraint = dividerHeight
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            headerHeight,
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            dividerHeight,
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pointerObserver.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pointerObserver.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pointerObserver.topAnchor.constraint(equalTo: root.topAnchor),
            pointerObserver.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            flashRing.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            flashRing.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            flashRing.topAnchor.constraint(equalTo: root.topAnchor),
            flashRing.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func update(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        loadViewIfNeeded()
        guard let panel = configuration.panel as? FilePreviewPanel else { return }
        observe(panel)
        refresh(panel: panel)
    }

    func teardownPanelContent() {
        panelCancellable = nil
        defaultsTask?.cancel()
        defaultsTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        externalApplicationTask?.cancel()
        externalApplicationTask = nil
        revisionObservationGeneration &+= 1
        if installedContent == .preview(.quickLook), let installedView, let panel {
            panel.nativeViewSessions.quickLook.dismantle(installedView)
        } else {
            installedView?.removeFromSuperview()
        }
        installedView = nil
        installedContent = nil
        textEditorController?.panel = nil
        textEditorController = nil
        header.teardown()
        pointerObserver.onPointerDown = nil
        panel = nil
    }

    isolated deinit {
        defaultsTask?.cancel()
        refreshTask?.cancel()
        externalApplicationTask?.cancel()
    }

    private func observe(_ panel: FilePreviewPanel) {
        guard self.panel !== panel else { return }
        panelCancellable = panel.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.scheduleRefresh()
            }
        }
        defaultsTask?.cancel()
        defaultsTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UserDefaults.didChangeNotification,
                object: UserDefaults.standard
            ) {
                guard !Task.isCancelled else { return }
                self?.scheduleRefresh()
            }
        }
        self.panel = panel
        lastFocusFlashToken = panel.focusFlashToken
        observeRevision(panel.previewRevisionState)
        resolveExternalApplications(for: panel.fileURL)
    }

    private func observeRevision(_ revision: FilePreviewRevision) {
        revisionObservationGeneration &+= 1
        let generation = revisionObservationGeneration
        withObservationTracking {
            _ = revision.value
        } onChange: { [weak self, weak revision] in
            Task { @MainActor [weak self, weak revision] in
                guard let self, let revision,
                      self.revisionObservationGeneration == generation else { return }
                self.observeRevision(revision)
                self.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            self.refresh(panel: panel)
        }
    }

    private func refresh(panel: FilePreviewPanel) {
        let appearance = configuration.appearance
        let backgroundColor = appearance.contentBackgroundColor
        view.layer?.backgroundColor = backgroundColor.cgColor
        contentContainer.layer?.backgroundColor = backgroundColor.cgColor
        view.appearance = NSAppearance(named: appearance.backgroundColor.isLightColor ? .aqua : .darkAqua)
        pointerObserver.isHidden = !configuration.isVisibleInUI
        pointerObserver.onPointerDown = configuration.onRequestPanelFocus

        header.update(
            panel: panel,
            foregroundColor: appearance.foregroundColor,
            externalLabel: externalHelpText,
            onRevert: { [weak panel] in _ = panel?.loadTextContent() },
            onSave: { [weak panel] in _ = panel?.saveTextContent() },
            onRefresh: { [weak panel] in _ = panel?.reloadFromDisk() },
            onOpenExternally: { [weak self] button in self?.presentExternalMenu(relativeTo: button) }
        )

        let showsHeader = panel.previewMode != .pdf || panel.isFileUnavailable
        header.isHidden = !showsHeader
        divider.isHidden = !showsHeader
        headerHeightConstraint?.constant = showsHeader ? 30 : 0
        dividerHeightConstraint?.constant = showsHeader ? 1 : 0

        if panel.isFileUnavailable {
            unavailableView.update(filePath: panel.filePath)
            install(unavailableView, as: .unavailable)
        } else {
            installPreview(panel: panel, appearance: appearance)
        }

        if configuration.isFocused {
            panel.retryPendingFocus()
        }
        if lastFocusFlashToken != panel.focusFlashToken {
            lastFocusFlashToken = panel.focusFlashToken
            flashRing.triggerFlash(reason: .navigation)
        }
    }

    private func installPreview(panel: FilePreviewPanel, appearance: PanelAppearance) {
        let mode = panel.previewMode
        let backgroundColor = appearance.contentBackgroundColor
        let revision = panel.previewRevision
        let isVisible = configuration.isVisibleInUI
        let target = InstalledContent.preview(mode)

        switch mode {
        case .text:
            let editor = textEditorController ?? FilePreviewTextEditorController(
                panel: panel,
                isVisibleInUI: isVisible,
                themeBackgroundColor: backgroundColor,
                themeForegroundColor: appearance.foregroundColor,
                drawsBackground: appearance.drawsContentBackground,
                wordWrap: FilePreviewWordWrapSettings.isEnabled()
            )
            textEditorController = editor
            editor.configure(
                panel: panel,
                isVisibleInUI: isVisible,
                themeBackgroundColor: backgroundColor,
                themeForegroundColor: appearance.foregroundColor,
                drawsBackground: appearance.drawsContentBackground,
                wordWrap: FilePreviewWordWrapSettings.isEnabled()
            )
            install(editor.scrollView, as: target)
        case .pdf:
            let session = panel.nativeViewSessions.pdf
            if installedContent == target, let view = installedView as? FilePreviewPDFContainerView {
                session.update(
                    view,
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            } else {
                install(session.view(
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                ), as: target)
            }
        case .image:
            let session = panel.nativeViewSessions.image
            if installedContent == target, let view = installedView as? FilePreviewImageContainerView {
                session.update(
                    view,
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            } else {
                install(session.view(
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                ), as: target)
            }
        case .media:
            let session = panel.nativeViewSessions.media
            if installedContent == target, let view = installedView as? AVPlayerView {
                session.update(
                    view,
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            } else {
                install(session.view(
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                ), as: target)
            }
        case .quickLook:
            let session = panel.nativeViewSessions.quickLook
            if installedContent == target, let view = installedView {
                session.update(
                    view,
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            } else {
                install(session.view(
                    panel: panel,
                    revision: revision,
                    isVisibleInUI: isVisible,
                    backgroundColor: backgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                ), as: target)
            }
        }
    }

    private func install(_ contentView: NSView, as content: InstalledContent) {
        guard installedView !== contentView || installedContent != content else { return }
        if installedContent == .preview(.quickLook), let installedView, let panel {
            panel.nativeViewSessions.quickLook.dismantle(installedView)
        } else {
            installedView?.removeFromSuperview()
        }
        contentView.removeFromSuperview()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        installedView = contentView
        installedContent = content
    }

    private func resolveExternalApplications(for fileURL: URL) {
        externalApplications = []
        externalApplicationTask?.cancel()
        externalApplicationTask = Task { @MainActor [weak self] in
            let applications = await Task.detached(priority: .userInitiated) {
                FileExternalOpenApplicationResolver.live.applications(for: fileURL)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.externalApplications = applications
            self.scheduleRefresh()
        }
    }

    private var externalHelpText: String {
        if let application = externalApplications.first(where: \.isDefault) ?? externalApplications.first {
            return FileExternalOpenText.openInApplication(application.displayName)
        }
        return FileExternalOpenText.openExternally
    }

    private func presentExternalMenu(relativeTo button: NSButton) {
        guard let panel, !panel.isFileUnavailable else { return }
        let applications = externalApplications.isEmpty
            ? FileExternalOpenApplicationResolver.live.applications(for: panel.fileURL)
            : externalApplications
        let primary = applications.first(where: \.isDefault) ?? applications.first
        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: panel.fileURL,
            primaryApplication: primary,
            otherApplications: applications.filter { $0.id != primary?.id }
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }
}

@MainActor
private final class FilePreviewPanelHeaderNativeView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let controls = NSStackView()
    private let revertButton = PanelHeaderNativeButton(
        systemName: "arrow.counterclockwise",
        label: String(localized: "filePreview.revert", defaultValue: "Revert")
    )
    private let saveButton = PanelHeaderNativeButton(
        systemName: "square.and.arrow.down",
        label: String(localized: "filePreview.save", defaultValue: "Save")
    )
    private let refreshButton = PanelHeaderNativeButton(
        systemName: "arrow.clockwise",
        label: String(localized: "filePreview.refresh", defaultValue: "Refresh")
    )
    private let externalButton = PanelHeaderNativeButton(systemName: "square.and.arrow.up", label: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.isSelectable = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        [revertButton, saveButton, refreshButton, externalButton].forEach(controls.addArrangedSubview)
        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(controls)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        panel: FilePreviewPanel,
        foregroundColor: NSColor,
        externalLabel: String,
        onRevert: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onOpenExternally: @escaping (NSButton) -> Void
    ) {
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: panel.displayIcon ?? "doc.viewfinder",
            pointSize: 16,
            weight: .regular
        )
        pathLabel.stringValue = panel.filePath
        pathLabel.textColor = foregroundColor.withAlphaComponent(0.68)
        let showsEditingControls = panel.previewMode == .text
        revertButton.isHidden = !showsEditingControls
        saveButton.isHidden = !showsEditingControls
        revertButton.isEnabled = panel.isDirty
        saveButton.isEnabled = panel.isDirty && !panel.isSaving
        externalButton.isEnabled = !panel.isFileUnavailable
        externalButton.update(systemName: "square.and.arrow.up", label: externalLabel)
        revertButton.actionClosure = onRevert
        saveButton.actionClosure = onSave
        refreshButton.actionClosure = onRefresh
        externalButton.actionClosure = { [weak externalButton] in
            guard let externalButton else { return }
            onOpenExternally(externalButton)
        }
    }

    func teardown() {
        [revertButton, saveButton, refreshButton, externalButton].forEach { $0.actionClosure = nil }
    }
}

private enum FilePreviewPDFSidebarMode {
    case thumbnails
    case tableOfContents
}

private enum FilePreviewPDFDisplayMode {
    case continuousScroll
    case singlePage
    case twoPages
}

enum FilePreviewPDFChromeStyleVariant: String, CaseIterable, Identifiable {
    case systemControlGroup
    case liquidGlass
    case materialCapsule
    case borderedCapsule
    case thinOutline
    case plainToolbar

    static let defaultsKey = "filePreviewPDFChromeStyleVariant"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemControlGroup:
            String(localized: "filePreview.pdf.chromeStyle.systemControlGroup", defaultValue: "A: System Control Group")
        case .liquidGlass:
            String(localized: "filePreview.pdf.chromeStyle.liquidGlass", defaultValue: "B: Liquid Glass")
        case .materialCapsule:
            String(localized: "filePreview.pdf.chromeStyle.materialCapsule", defaultValue: "C: Material Pill")
        case .borderedCapsule:
            String(localized: "filePreview.pdf.chromeStyle.borderedCapsule", defaultValue: "D: Bordered Controls")
        case .thinOutline:
            String(localized: "filePreview.pdf.chromeStyle.thinOutline", defaultValue: "E: Thin Outline")
        case .plainToolbar:
            String(localized: "filePreview.pdf.chromeStyle.plainToolbar", defaultValue: "F: Plain Toolbar")
        }
    }

    static func current() -> FilePreviewPDFChromeStyleVariant {
        #if DEBUG
        if let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
           let variant = FilePreviewPDFChromeStyleVariant(rawValue: rawValue) {
            return variant
        }
        #endif
        return .liquidGlass
    }

    func persist() {
        #if DEBUG
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .filePreviewPDFChromeStyleDidChange, object: nil)
        #endif
    }
}

extension Notification.Name {
    static let filePreviewPDFChromeStyleDidChange = Notification.Name("filePreviewPDFChromeStyleDidChange")
}

final class FilePreviewPDFChromeHostView: NSView {
    var interactiveOverlayViews: [NSView] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        for overlayView in interactiveOverlayViews.reversed() where !overlayView.isHidden {
            let convertedPoint = convert(point, to: overlayView)
            if let hitView = interactiveHit(in: overlayView, at: convertedPoint) {
                return hitView
            }
        }
        return nil
    }

    private func interactiveHit(in view: NSView, at point: NSPoint) -> NSView? {
        guard !view.isHidden, view.bounds.contains(point) else { return nil }
        for subview in view.subviews.reversed() {
            let convertedPoint = view.convert(point, to: subview)
            if let hitView = interactiveHit(in: subview, at: convertedPoint) {
                return hitView
            }
        }
        return view is NSControl || view is FilePreviewPDFChromeHostingView ? view : nil
    }
}

final class FilePreviewPDFChromeHostingView: NSView {
    private weak var installedContentView: NSView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setContentView(_ view: NSView) {
        installedContentView?.removeFromSuperview()
        installedContentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
private final class FilePreviewPDFSidebarChromeView: NSView {
    private enum Action: Int {
        case toggleSidebar
        case thumbnails
        case tableOfContents
        case continuousScroll
        case singlePage
        case twoPages
    }

    private let toggleSidebar: () -> Void
    private let selectThumbnails: () -> Void
    private let selectTableOfContents: () -> Void
    private let selectContinuousScroll: () -> Void
    private let selectSinglePage: () -> Void
    private let selectTwoPages: () -> Void
    private let isSidebarVisible: Bool
    private let sidebarMode: FilePreviewPDFSidebarMode
    private let displayMode: FilePreviewPDFDisplayMode

    init(
        isSidebarVisible: Bool,
        sidebarMode: FilePreviewPDFSidebarMode,
        displayMode: FilePreviewPDFDisplayMode,
        chromeStyleVariant: FilePreviewPDFChromeStyleVariant,
        toggleSidebar: @escaping () -> Void,
        selectThumbnails: @escaping () -> Void,
        selectTableOfContents: @escaping () -> Void,
        selectContinuousScroll: @escaping () -> Void,
        selectSinglePage: @escaping () -> Void,
        selectTwoPages: @escaping () -> Void
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.sidebarMode = sidebarMode
        self.displayMode = displayMode
        self.toggleSidebar = toggleSidebar
        self.selectThumbnails = selectThumbnails
        self.selectTableOfContents = selectTableOfContents
        self.selectContinuousScroll = selectContinuousScroll
        self.selectSinglePage = selectSinglePage
        self.selectTwoPages = selectTwoPages
        super.init(frame: .zero)

        let label = String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options")
        let button = FilePreviewChromeButton(
            systemName: "sidebar.left",
            label: label,
            variant: chromeStyleVariant,
            action: {}
        )
        button.target = self
        button.action = #selector(showMenu(_:))
        let group = FilePreviewPDFChromeGroupView(variant: chromeStyleVariant, content: button)
        group.translatesAutoresizingMaskIntoConstraints = false
        addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: leadingAnchor),
            group.trailingAnchor.constraint(equalTo: trailingAnchor),
            group.topAnchor.constraint(equalTo: topAnchor),
            group.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        addItem(
            isSidebarVisible
                ? String(localized: "filePreview.pdf.hideSidebar", defaultValue: "Hide Sidebar")
                : String(localized: "filePreview.pdf.showSidebar", defaultValue: "Show Sidebar"),
            action: .toggleSidebar,
            to: menu
        )
        addItem(
            String(localized: "filePreview.pdf.thumbnails", defaultValue: "Thumbnails"),
            action: .thumbnails,
            selected: sidebarMode == .thumbnails,
            to: menu
        )
        addItem(
            String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents"),
            action: .tableOfContents,
            selected: sidebarMode == .tableOfContents,
            to: menu
        )
        menu.addItem(.separator())
        addItem(
            String(localized: "filePreview.pdf.continuousScroll", defaultValue: "Continuous Scroll"),
            action: .continuousScroll,
            selected: displayMode == .continuousScroll,
            to: menu
        )
        addItem(
            String(localized: "filePreview.pdf.singlePage", defaultValue: "Single Page"),
            action: .singlePage,
            selected: displayMode == .singlePage,
            to: menu
        )
        addItem(
            String(localized: "filePreview.pdf.twoPages", defaultValue: "Two Pages"),
            action: .twoPages,
            selected: displayMode == .twoPages,
            to: menu
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    private func addItem(
        _ title: String,
        action: Action,
        selected: Bool = false,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = action.rawValue
        item.state = selected ? .on : .off
        menu.addItem(item)
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = Action(rawValue: sender.tag) else { return }
        switch action {
        case .toggleSidebar: toggleSidebar()
        case .thumbnails: selectThumbnails()
        case .tableOfContents: selectTableOfContents()
        case .continuousScroll: selectContinuousScroll()
        case .singlePage: selectSinglePage()
        case .twoPages: selectTwoPages()
        }
    }
}

final class FilePreviewPDFThumbnailSidebarView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    private enum Metrics {
        static let thumbnailHeight = FilePreviewPDFSizing.thumbnailMaximumSize.height
        static func labelHeight() -> CGFloat {
            let font = GlobalFontMagnification.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            return max(22, ceil(font.ascender - font.descender + font.leading) + 8)
        }
        static let itemSpacing: CGFloat = 12
        static let verticalInset: CGFloat = 24
    }

    private let scrollView = NSScrollView()
    private let collectionView = FilePreviewPDFThumbnailCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private var document: PDFDocument?
    private var labelHeight = Metrics.labelHeight()
    private var isApplyingSelection = false
    private var selectedPageIndex: Int?
    private var selectionIsActive = false

    var onSelectPage: ((PDFPage) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onPageNavigation: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }
    override func layout() {
        super.layout()
        updateItemSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateItemSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateItemSize()
    }

    func setDocument(_ document: PDFDocument?) {
        self.document = document
        selectedPageIndex = nil
        collectionView.reloadData()
        selectPage(at: 0, scrollToVisible: false)
    }

    func reloadFontsForGlobalMagnification() {
        labelHeight = Metrics.labelHeight(); flowLayout.invalidateLayout()
        collectionView.reloadData()
        updateItemSize()
    }

    func selectPage(at pageIndex: Int, scrollToVisible: Bool) {
        guard let document, pageIndex >= 0, pageIndex < document.pageCount else {
            selectedPageIndex = nil
            collectionView.deselectAll(nil)
            return
        }

        isApplyingSelection = true
        let previousPageIndex = selectedPageIndex
        selectedPageIndex = pageIndex
        let indexPath = IndexPath(item: pageIndex, section: 0)
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [indexPath], scrollPosition: scrollToVisible ? .centeredVertically : [])
        let reloadIndexPaths = [previousPageIndex, selectedPageIndex]
            .compactMap { $0 }
            .filter { $0 >= 0 && $0 < document.pageCount }
            .map { IndexPath(item: $0, section: 0) }
        if !reloadIndexPaths.isEmpty {
            collectionView.reloadItems(at: Set(reloadIndexPaths))
        }
        isApplyingSelection = false
    }

    func reloadPage(at pageIndex: Int) {
        guard let document, pageIndex >= 0, pageIndex < document.pageCount else { return }
        collectionView.reloadItems(at: [IndexPath(item: pageIndex, section: 0)])
    }

    func setSelectionActive(_ isActive: Bool) {
        guard selectionIsActive != isActive else { return }
        selectionIsActive = isActive
        for item in collectionView.visibleItems() {
            (item as? FilePreviewPDFThumbnailItem)?.isSelectionActiveForPreview = isActive
        }
    }

    func preferredSidebarWidth() -> CGFloat {
        FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)
    }

    func focusResponder() -> NSView {
        collectionView
    }

    private func setupView() {
        flowLayout.scrollDirection = .vertical
        flowLayout.minimumLineSpacing = Metrics.itemSpacing
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = NSEdgeInsets(
            top: Metrics.verticalInset,
            left: 0,
            bottom: Metrics.verticalInset,
            right: 0
        )

        collectionView.collectionViewLayout = flowLayout
        collectionView.autoresizingMask = [.width]
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.onFocusChanged = { [weak self] isActive in
            self?.onFocusChanged?(isActive)
        }
        collectionView.onPageNavigation = { [weak self] delta in
            self?.onPageNavigation?(delta)
        }
        collectionView.onPrimaryClickItem = { [weak self] pageIndex in
            self?.selectPageFromPrimaryClick(at: pageIndex)
        }
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.register(
            FilePreviewPDFThumbnailItem.self,
            forItemWithIdentifier: FilePreviewPDFThumbnailItem.reuseIdentifier
        )

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateItemSize() {
        let itemWidth = thumbnailItemWidth()
        if abs(collectionView.frame.width - itemWidth) > 0.5 {
            collectionView.setFrameSize(NSSize(width: itemWidth, height: collectionView.frame.height))
        }
        let nextSize = thumbnailItemSize(width: itemWidth)
        guard flowLayout.itemSize != nextSize else { return }
        flowLayout.itemSize = nextSize
        flowLayout.invalidateLayout()
    }

    private func thumbnailItemWidth() -> CGFloat {
        let contentWidth = scrollView.contentView.bounds.width
        let scrollWidth = scrollView.bounds.width
        let fallbackWidth = bounds.width
        return max(1, contentWidth, scrollWidth, fallbackWidth)
    }

    private func thumbnailItemSize(width: CGFloat) -> NSSize {
        NSSize(
            width: max(1, width),
            height: Metrics.thumbnailHeight + labelHeight + 10
        )
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        document?.pageCount ?? 0
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: FilePreviewPDFThumbnailItem.reuseIdentifier,
            for: indexPath
        ) as? FilePreviewPDFThumbnailItem ?? FilePreviewPDFThumbnailItem()
        let page = document?.page(at: indexPath.item)
        item.configure(
            page: page,
            pageNumber: indexPath.item + 1,
            isSelectedForPreview: indexPath.item == selectedPageIndex,
            isSelectionActiveForPreview: selectionIsActive
        )
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingSelection,
              let pageIndex = indexPaths.first?.item,
              let page = document?.page(at: pageIndex) else { return }
        window?.makeFirstResponder(collectionView)
        setSelectionActive(true)
        onSelectPage?(page)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        thumbnailItemSize(width: thumbnailItemWidth())
    }

    private func selectPageFromPrimaryClick(at pageIndex: Int) {
        guard let document,
              pageIndex >= 0,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }
        window?.makeFirstResponder(collectionView)
        setSelectionActive(true)
        selectPage(at: pageIndex, scrollToVisible: false)
        onSelectPage?(page)
    }
}

private final class FilePreviewPDFOutlineView: NSOutlineView {
    var onFocusChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

private final class FilePreviewPDFThumbnailItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("filePreviewPDFThumbnailItem")

    private var thumbnailItemView: FilePreviewPDFThumbnailItemView? {
        view as? FilePreviewPDFThumbnailItemView
    }

    override var isSelected: Bool {
        didSet {
            thumbnailItemView?.isSelectedForPreview = isSelected
        }
    }

    var isSelectionActiveForPreview = false {
        didSet {
            thumbnailItemView?.isSelectionActiveForPreview = isSelectionActiveForPreview
        }
    }

    override func loadView() {
        view = FilePreviewPDFThumbnailItemView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailItemView?.configure(image: nil, pageNumber: "")
        thumbnailItemView?.isSelectedForPreview = false
        thumbnailItemView?.isSelectionActiveForPreview = false
    }

    func configure(
        page: PDFPage?,
        pageNumber: Int,
        isSelectedForPreview: Bool,
        isSelectionActiveForPreview: Bool
    ) {
        let thumbnail = page?.thumbnail(of: FilePreviewPDFSizing.thumbnailMaximumSize, for: .cropBox)
        thumbnailItemView?.configure(image: thumbnail, pageNumber: "\(pageNumber)")
        thumbnailItemView?.isSelectedForPreview = isSelectedForPreview
        thumbnailItemView?.isSelectionActiveForPreview = isSelectionActiveForPreview
    }
}

private final class FilePreviewPDFThumbnailItemView: NSView {
    private enum Metrics {
        static let selectionHorizontalInset: CGFloat = 8
        static let thumbnailHorizontalInset: CGFloat = 4
    }

    private let selectionView = NSView()
    private let imageView = NSImageView()
    private let pageLabel = NSTextField(labelWithString: "")

    var isSelectedForPreview = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    var isSelectionActiveForPreview = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(image: NSImage?, pageNumber: String) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        imageView.image = image
        pageLabel.stringValue = pageNumber
    }

    private func setupView() {
        wantsLayer = true

        selectionView.wantsLayer = true
        selectionView.layer?.cornerRadius = 10
        selectionView.layer?.masksToBounds = true
        selectionView.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        pageLabel.alignment = .center
        pageLabel.font = GlobalFontMagnification.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        pageLabel.lineBreakMode = .byTruncatingTail
        pageLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionView)
        addSubview(imageView)
        addSubview(pageLabel)

        NSLayoutConstraint.activate([
            selectionView.topAnchor.constraint(equalTo: topAnchor),
            selectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.selectionHorizontalInset),
            selectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.selectionHorizontalInset),
            selectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: selectionView.topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: selectionView.leadingAnchor, constant: Metrics.thumbnailHorizontalInset),
            imageView.trailingAnchor.constraint(equalTo: selectionView.trailingAnchor, constant: -Metrics.thumbnailHorizontalInset),
            imageView.heightAnchor.constraint(equalToConstant: 106),

            pageLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            pageLabel.centerXAnchor.constraint(equalTo: selectionView.centerXAnchor),
            pageLabel.bottomAnchor.constraint(lessThanOrEqualTo: selectionView.bottomAnchor, constant: -5),
        ])
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        if isSelectedForPreview {
            selectionView.layer?.backgroundColor = (isSelectionActiveForPreview
                ? NSColor.selectedContentBackgroundColor
                : NSColor.unemphasizedSelectedContentBackgroundColor
            ).cgColor
        } else {
            selectionView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        pageLabel.textColor = isSelectedForPreview
            ? (isSelectionActiveForPreview ? .white : .labelColor)
            : .secondaryLabelColor
    }
}

final class FilePreviewPDFContainerView: NSView, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let visiblePageResolver = FilePreviewPDFVisiblePageResolver()
    private enum Metrics {
        static let defaultSidebarWidth = FilePreviewPDFSizing.defaultSidebarWidth
        static let minimumSidebarWidth = FilePreviewPDFSizing.minimumSidebarWidth
        static let maximumSidebarWidth = FilePreviewPDFSizing.maximumSidebarWidth
        static let floatingChromeHeight: CGFloat = 40
        static let floatingControlsWidth: CGFloat = 394
        static let floatingChromeCornerRadius: CGFloat = 20
    }

    private let splitView = NSSplitView()
    private let sidebarHost = NSVisualEffectView()
    private let contentHost = NSView()
    private let chromeHost = FilePreviewPDFChromeHostView()
    private let pdfView = FilePreviewMagnifyingPDFView()
    private let thumbnailView = FilePreviewPDFThumbnailSidebarView()
    private let outlineScrollView = NSScrollView()
    private let outlineView = FilePreviewPDFOutlineView()
    private let outlinePlaceholder = NSTextField(wrappingLabelWithString: "")
    private let sidebarChromeHost = FilePreviewPDFChromeHostingView()
    private let zoomChromeHost = FilePreviewPDFChromeHostingView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private weak var panel: FilePreviewPanel?
    private var currentURL: URL?
    private var currentRevision: Int?
    private var loadGeneration = 0
    private var pendingReloadViewport: FilePreviewPDFViewportSnapshot?
    private var pendingReloadWasAutoScaled: Bool?
    private var pendingReloadScale: CGFloat?
    private var outlineRoot: PDFOutline?
    private var sidebarMode: FilePreviewPDFSidebarMode = .thumbnails
    private var displayMode: FilePreviewPDFDisplayMode = .continuousScroll
    private var isSidebarVisible = true
    private var chromeStyleVariant = FilePreviewPDFChromeStyleVariant.current()
    private var didSetInitialSidebarWidth = false
    private var lastSidebarWidth = Metrics.defaultSidebarWidth
    private var didUserResizeSidebar = false
    private var isApplyingSidebarWidth = false
    private var pendingSidebarResizeSnapshot: FilePreviewPDFViewportSnapshot?
    private var suppressPDFPageChangeNotifications = false
    private var pdfResizeSequence = 0
    private var activePDFResizeID: Int?
    private var activePDFRegion: FilePreviewPanelFocusIntent?
    private weak var observedPDFClipView: NSClipView?
    private var rotationAccumulator: CGFloat = 0
    private var pageRotationState = FilePreviewPDFPageRotationState()
    private var previewBackgroundColor = NSColor.textBackgroundColor
    private var drawsPreviewBackground = true
    private var lastAppliedPDFScrollBackgroundAppearance: PDFScrollBackgroundAppearance?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
    private let documentLoader = FilePreviewLatestLoadCoordinator<FilePreviewPDFLoadResult>()

    private struct PDFScrollBackgroundAppearance {
        let hostIdentifiers: Set<ObjectIdentifier>
        let backgroundColor: NSColor
        let drawsBackground: Bool

        func matches(_ other: PDFScrollBackgroundAppearance) -> Bool {
            hostIdentifiers == other.hostIdentifiers
                && drawsBackground == other.drawsBackground
                && backgroundColor.isEqual(other.backgroundColor)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyFloatingChromeFonts()
            self?.thumbnailView.reloadFontsForGlobalMagnification()
            self?.outlineView.reloadData()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removePDFScrollObserver()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerFocusEndpoint()
        updatePDFThumbnailSelectionFocus()
    }

    override func layout() {
        super.layout()
        applyBackgroundAppearance()
        if !didSetInitialSidebarWidth, bounds.width > 0 {
            didSetInitialSidebarWidth = true
            let initialWidth = clampedSidebarWidth(lastSidebarWidth)
            lastSidebarWidth = initialWidth
            splitView.setPosition(initialWidth, ofDividerAt: 0)
            splitView.adjustSubviews()
            refreshPDFSmartFitWithoutViewportRestore()
        }
        layoutFloatingChrome()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let chromePoint = convert(point, to: chromeHost)
        if let chromeHit = chromeHost.hitTest(chromePoint) {
            return chromeHit
        }
        return super.hitTest(point)
    }

    func setPanel(_ panel: FilePreviewPanel) {
        self.panel = panel
        registerFocusEndpoint()
    }

    func close() {
        removeFromSuperview()
        removePDFScrollObserver()
        NotificationCenter.default.removeObserver(self)
        pdfView.document = nil
        thumbnailView.setDocument(nil)
        outlineRoot = nil
        currentURL = nil
        currentRevision = nil
        loadGeneration &+= 1
        documentLoader.cancel()
        pendingReloadViewport = nil
        pendingReloadWasAutoScaled = nil
        pendingReloadScale = nil
        panel = nil
    }

    func setBackgroundAppearance(backgroundColor: NSColor, drawsBackground: Bool) {
        guard previewBackgroundColor != backgroundColor || drawsPreviewBackground != drawsBackground else { return }
        previewBackgroundColor = backgroundColor
        drawsPreviewBackground = drawsBackground
        invalidatePDFScrollBackgroundAppearance()
        applyBackgroundAppearance()
    }

    func setURL(_ url: URL, revision: Int) {
        guard currentURL != url || currentRevision != revision else {
            applyPreferredSidebarWidthIfNeeded()
            updatePageControls()
            refreshPDFSmartFitPreservingVisibleTop()
            return
        }
        let isReload = currentURL == url
        if isReload, pendingReloadViewport == nil {
            preparePDFViewportSnapshot()
            pendingReloadViewport = FilePreviewPDFViewportSnapshot.capture(
                in: pdfView,
                scrollView: pdfScrollView(),
                anchor: .top
            )
            pendingReloadWasAutoScaled = pdfView.autoScales
            pendingReloadScale = pdfView.scaleFactor
        }
        currentURL = url
        currentRevision = revision
        loadGeneration &+= 1
        let generation = loadGeneration
        updateChromeRootViews()
        pdfView.document = nil
        thumbnailView.setDocument(nil)
        outlineRoot = nil
        titleLabel.stringValue = url.lastPathComponent
        if !isReload {
            rotationAccumulator = 0
            pageRotationState.reset()
            didUserResizeSidebar = false
            lastSidebarWidth = preferredSidebarWidthForCurrentMode()
            pdfView.autoScales = true
            applyDisplayMode()
        }
        outlineView.reloadData()
        updateSidebarContent()
        applyPreferredSidebarWidthIfNeeded()
        updatePageControls()
        refreshPDFSmartFitWithoutViewportRestore()

        let loadURL = url
        documentLoader.submit(load: { await FilePreviewPDFLoadResult.load(url: loadURL) }) { [weak self] result in
            guard let self,
                  self.currentURL == loadURL,
                  self.loadGeneration == generation else { return }
            self.applyLoadedPDFDocument(result.document, for: loadURL)
        }
    }

    private func applyLoadedPDFDocument(_ document: PDFDocument?, for url: URL) {
        let reloadViewport = pendingReloadViewport
        let reloadWasAutoScaled = pendingReloadWasAutoScaled
        let reloadScale = pendingReloadScale
        pendingReloadViewport = nil
        pendingReloadWasAutoScaled = nil
        pendingReloadScale = nil

        pageRotationState.apply(to: document)
        pdfView.document = document
        thumbnailView.setDocument(document)
        outlineRoot = document?.outlineRoot
        titleLabel.stringValue = url.lastPathComponent
        applyDisplayMode()
        if let reloadWasAutoScaled {
            pdfView.autoScales = reloadWasAutoScaled
            if !reloadWasAutoScaled, let reloadScale {
                pdfView.scaleFactor = min(max(reloadScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
            }
        } else {
            pdfView.autoScales = true
        }
        updatePDFScrollObserver()
        outlineView.reloadData()
        updateSidebarContent()
        applyPreferredSidebarWidthIfNeeded()
        updatePageControls(scrollThumbnailToVisible: false)
        invalidatePDFScrollBackgroundAppearance()
        applyBackgroundAppearance()
        refreshPDFSmartFitWithoutViewportRestore()
        if let reloadViewport {
            withSuppressedPDFPageChangeNotifications {
                reloadViewport.restore(in: pdfView, scrollView: pdfScrollView())
            }
            updatePageControls(scrollThumbnailToVisible: false)
        }
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        setupSplitView()
        setupSidebar()
        setupPDFView()
        setupFloatingChrome()
        applyBackgroundAppearance()

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8.0
        pdfView.onMagnify = { [weak self] event in
            let factor = 1.0 + event.magnification
            self?.zoomPDF(with: event, factor: factor)
        }
        pdfView.onScrollZoom = { [weak self] event in
            self?.zoomPDF(with: event, factor: FilePreviewInteraction.zoomFactor(forScroll: event))
        }
        pdfView.onScroll = { [weak self] in
            self?.updatePageControls()
        }
        pdfView.onSmartMagnify = { [weak self] in
            self?.togglePDFSmartZoom()
        }
        pdfView.onRotate = { [weak self] event in
            self?.rotatePDF(with: event)
        }
        pdfView.onSwipe = { [weak self] event in
            self?.swipePDF(with: event)
        }
        updatePDFScrollObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfChromeStyleChanged),
            name: .filePreviewPDFChromeStyleDidChange,
            object: nil
        )
        registerFocusEndpoint()
    }

    private func setupSplitView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(contentHost)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupSidebar() {
        sidebarHost.material = .sidebar
        sidebarHost.blendingMode = .withinWindow
        sidebarHost.state = .active

        thumbnailView.onSelectPage = { [weak self] page in
            self?.setActivePDFRegion(.pdfThumbnails)
            self?.goToPDFPage(page, scrollThumbnailToVisible: false)
        }
        thumbnailView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfThumbnails : nil)
        }
        thumbnailView.onPageNavigation = { [weak self] delta in
            self?.navigatePDFPage(by: delta)
        }
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filePreviewPDFOutline"))
        outlineColumn.title = String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents")
        outlineView.addTableColumn(outlineColumn)
        outlineView.outlineTableColumn = outlineColumn
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfOutline : nil)
        }
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.autohidesScrollers = true
        outlineScrollView.borderType = .noBorder
        outlineScrollView.drawsBackground = false
        outlineScrollView.documentView = outlineView
        outlineScrollView.translatesAutoresizingMaskIntoConstraints = false

        outlinePlaceholder.stringValue = String(
            localized: "filePreview.pdf.noTableOfContents",
            defaultValue: "No table of contents"
        )
        outlinePlaceholder.alignment = .center
        outlinePlaceholder.textColor = .secondaryLabelColor
        outlinePlaceholder.translatesAutoresizingMaskIntoConstraints = false

        sidebarHost.addSubview(thumbnailView)
        sidebarHost.addSubview(outlineScrollView)
        sidebarHost.addSubview(outlinePlaceholder)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            outlineScrollView.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            outlineScrollView.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            outlineScrollView.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            outlineScrollView.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            outlinePlaceholder.centerXAnchor.constraint(equalTo: sidebarHost.centerXAnchor),
            outlinePlaceholder.centerYAnchor.constraint(equalTo: sidebarHost.centerYAnchor),
            outlinePlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarHost.leadingAnchor, constant: 16),
            outlinePlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: sidebarHost.trailingAnchor, constant: -16),
        ])
    }

    private func setupPDFView() {
        contentHost.wantsLayer = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfCanvas : nil)
        }
        contentHost.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    private func applyBackgroundAppearance() {
        FilePreviewNativeBackground.applyRootLayer(
            to: self,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        FilePreviewNativeBackground.applyRootLayer(
            to: contentHost,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        let resolvedBackgroundColor = FilePreviewNativeBackground.resolvedColor(
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        pdfView.backgroundColor = resolvedBackgroundColor
        let scrollBackgroundAppearance = currentPDFScrollBackgroundAppearance(
            resolvedBackgroundColor: resolvedBackgroundColor
        )
        guard shouldApplyPDFScrollBackground(scrollBackgroundAppearance) else { return }
        FilePreviewNativeBackground.applyScrollBackgrounds(
            in: pdfView,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        lastAppliedPDFScrollBackgroundAppearance = scrollBackgroundAppearance
    }

    private func invalidatePDFScrollBackgroundAppearance() {
        lastAppliedPDFScrollBackgroundAppearance = nil
    }

    private func currentPDFScrollBackgroundAppearance(
        resolvedBackgroundColor: NSColor
    ) -> PDFScrollBackgroundAppearance {
        var hostIdentifiers = FilePreviewNativeBackground.scrollBackgroundHostIdentifiers(in: pdfView)
        if hostIdentifiers.isEmpty {
            hostIdentifiers.insert(ObjectIdentifier(pdfView))
        }
        return PDFScrollBackgroundAppearance(
            hostIdentifiers: hostIdentifiers,
            backgroundColor: resolvedBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
    }

    private func shouldApplyPDFScrollBackground(_ appearance: PDFScrollBackgroundAppearance) -> Bool {
        guard let lastAppliedPDFScrollBackgroundAppearance else { return true }
        return !lastAppliedPDFScrollBackgroundAppearance.matches(appearance)
    }

    private func setupFloatingChrome() {
        chromeHost.frame = bounds.width > 0 && bounds.height > 0
            ? bounds
            : NSRect(x: 0, y: 0, width: 480, height: 320)
        chromeHost.autoresizingMask = []
        addSubview(chromeHost, positioned: .above, relativeTo: splitView)

        sidebarChromeHost.translatesAutoresizingMaskIntoConstraints = false
        zoomChromeHost.translatesAutoresizingMaskIntoConstraints = false
        updateChromeRootViews()

        chromeHost.addSubview(sidebarChromeHost)
        chromeHost.addSubview(zoomChromeHost)
        chromeHost.interactiveOverlayViews = [sidebarChromeHost, zoomChromeHost]

        applyFloatingChromeFonts()
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pageLabel.textColor = .secondaryLabelColor
        pageLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, pageLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        chromeHost.addSubview(titleStack)

        let zoomWidthConstraint = zoomChromeHost.widthAnchor.constraint(equalToConstant: Metrics.floatingControlsWidth)
        zoomWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            sidebarChromeHost.topAnchor.constraint(equalTo: chromeHost.topAnchor, constant: 10),
            sidebarChromeHost.leadingAnchor.constraint(equalTo: chromeHost.leadingAnchor, constant: 10),
            sidebarChromeHost.widthAnchor.constraint(equalToConstant: 68),
            sidebarChromeHost.heightAnchor.constraint(equalToConstant: Metrics.floatingChromeHeight),

            zoomChromeHost.topAnchor.constraint(equalTo: chromeHost.topAnchor, constant: 10),
            zoomChromeHost.trailingAnchor.constraint(equalTo: chromeHost.trailingAnchor, constant: -10),
            zoomWidthConstraint,
            zoomChromeHost.heightAnchor.constraint(equalToConstant: Metrics.floatingChromeHeight),

            titleStack.leadingAnchor.constraint(equalTo: sidebarChromeHost.trailingAnchor, constant: 12),
            titleStack.centerYAnchor.constraint(equalTo: sidebarChromeHost.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: zoomChromeHost.leadingAnchor, constant: -12),
        ])
    }

    private func applyFloatingChromeFonts() {
        titleLabel.font = GlobalFontMagnification.systemFont(ofSize: 14, weight: .semibold)
        pageLabel.font = GlobalFontMagnification.systemFont(ofSize: 11)
    }

    private func layoutFloatingChrome() {
        let contentFrame = contentHost.convert(contentHost.bounds, to: self)
        guard contentFrame.width > 0, contentFrame.height > 0 else { return }
        if chromeHost.frame != contentFrame {
            chromeHost.frame = contentFrame
        }
        chromeHost.needsLayout = true
    }

    private func updateChromeRootViews() {
        sidebarChromeHost.setContentView(FilePreviewPDFSidebarChromeView(
            isSidebarVisible: isSidebarVisible,
            sidebarMode: sidebarMode,
            displayMode: displayMode,
            chromeStyleVariant: chromeStyleVariant,
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            selectThumbnails: { [weak self] in self?.selectThumbnailSidebar() },
            selectTableOfContents: { [weak self] in self?.selectTableOfContentsSidebar() },
            selectContinuousScroll: { [weak self] in self?.selectContinuousScroll() },
            selectSinglePage: { [weak self] in self?.selectSinglePage() },
            selectTwoPages: { [weak self] in self?.selectTwoPages() }
        ))
        zoomChromeHost.setContentView(FilePreviewPDFZoomChromeView(
            chromeStyleVariant: chromeStyleVariant,
            fileURL: currentURL,
            zoomOut: { [weak self] in self?.zoomOut() },
            actualSize: { [weak self] in self?.actualSize() },
            zoomIn: { [weak self] in self?.zoomIn() },
            zoomToFit: { [weak self] in self?.zoomToFit() },
            rotateLeft: { [weak self] in self?.rotateLeft() },
            rotateRight: { [weak self] in self?.rotateRight() },
            refresh: { [weak panel] in panel?.reloadFromDisk() }
        ))
    }

    @objc private func zoomOut() {
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor / FilePreviewInteraction.zoomStep, preservingVisibleCenter: true)
    }

    @objc private func zoomIn() {
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor * FilePreviewInteraction.zoomStep, preservingVisibleCenter: true)
    }

    @objc private func zoomToFit() {
        pdfView.autoScales = true
        refreshPDFSmartFitPreservingVisibleCenter()
    }

    @objc private func actualSize() {
        pdfView.autoScales = false
        setPDFScaleFactor(1.0, preservingVisibleCenter: true)
    }

    @objc private func rotateLeft() {
        rotateCurrentPDFPage(by: -90)
    }

    @objc private func rotateRight() {
        rotateCurrentPDFPage(by: 90)
    }

    @objc private func toggleSidebar() {
        isSidebarVisible.toggle()
        updateSidebarVisibility()
        updateChromeRootViews()
    }

    @objc private func selectThumbnailSidebar() {
        sidebarMode = .thumbnails
        isSidebarVisible = true
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        logSidebarWidth(reason: "selectThumbnails", proposed: lastSidebarWidth)
        updateSidebarVisibility()
        updateSidebarContent()
        updateChromeRootViews()
    }

    @objc private func selectTableOfContentsSidebar() {
        sidebarMode = .tableOfContents
        isSidebarVisible = true
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        logSidebarWidth(reason: "selectTableOfContents", proposed: lastSidebarWidth)
        updateSidebarVisibility()
        updateSidebarContent()
        updateChromeRootViews()
    }

    @objc private func selectContinuousScroll() {
        displayMode = .continuousScroll
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func selectSinglePage() {
        displayMode = .singlePage
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func selectTwoPages() {
        displayMode = .twoPages
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func pdfPageChanged() {
        logPDFResizeProbe(
            "pageChanged suppressed=\(suppressPDFPageChangeNotifications ? 1 : 0) \(pdfDebugState())"
        )
        guard !suppressPDFPageChangeNotifications else { return }
        updatePageControls()
    }

    @objc private func pdfChromeStyleChanged() {
        let variant = FilePreviewPDFChromeStyleVariant.current()
        guard variant != chromeStyleVariant else { return }
        chromeStyleVariant = variant
        updateChromeRootViews()
    }

    @objc private func pdfClipBoundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView === observedPDFClipView,
              pdfView.document != nil,
              !suppressPDFPageChangeNotifications else { return }
        updatePageControls()
    }

    private func updatePageControls(
        pageIndexOverride: Int? = nil,
        scrollThumbnailToVisible: Bool = true
    ) {
        guard let document = pdfView.document, document.pageCount > 0 else {
            pageLabel.stringValue = ""
            logPDFResizeProbe("updatePageControls emptyDoc scrollThumb=\(scrollThumbnailToVisible ? 1 : 0)")
            return
        }

        let pageIndex: Int
        if let pageIndexOverride,
           pageIndexOverride >= 0,
           pageIndexOverride < document.pageCount {
            pageIndex = pageIndexOverride
        } else if let visiblePageIndex = visiblePDFPageIndex(for: document) {
            pageIndex = visiblePageIndex
        } else {
            pageIndex = 0
        }
        let format = String(localized: "filePreview.pdf.pageCount", defaultValue: "Page %d of %d")
        pageLabel.stringValue = String.localizedStringWithFormat(format, pageIndex + 1, document.pageCount)
        thumbnailView.selectPage(at: pageIndex, scrollToVisible: scrollThumbnailToVisible)
        let explicit = pageIndexOverride == nil ? 0 : 1
        logPDFResizeProbe(
            "updatePageControls page=\(pageIndex + 1)/\(document.pageCount) " +
            "explicit=\(explicit) scrollThumb=\(scrollThumbnailToVisible ? 1 : 0) \(pdfDebugState())"
        )
    }

    private func visiblePDFPageIndex(for document: PDFDocument) -> Int? {
        let page = displayMode == .continuousScroll
            ? selectedVisiblePDFPage()
            : pdfView.currentPage
        guard let page else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }
        return pageIndex
    }

    private func selectedVisiblePDFPage() -> PDFPage? {
        visiblePageResolver.selectedVisiblePage(in: pdfView, scrollView: pdfScrollView())
    }

    private func topVisiblePDFPage() -> PDFPage? {
        visiblePageResolver.topVisiblePage(in: pdfView, scrollView: pdfScrollView())
    }

    private func updateSidebarVisibility() {
        if isSidebarVisible {
            sidebarHost.isHidden = false
            let targetWidth = didUserResizeSidebar
                ? lastSidebarWidth
                : preferredSidebarWidthForCurrentMode()
            applySidebarWidth(targetWidth)
        } else {
            let currentSidebarWidth = sidebarHost.frame.width
            if currentSidebarWidth >= minimumSidebarWidthForCurrentMode() {
                lastSidebarWidth = currentSidebarWidth
            }
            applyPDFViewportChange {
                self.sidebarHost.isHidden = true
                self.splitView.adjustSubviews()
                self.splitView.layoutSubtreeIfNeeded()
                self.layoutFloatingChrome()
            }
        }
        layoutFloatingChrome()
    }

    private func clampedSidebarWidth(_ proposedWidth: CGFloat) -> CGFloat {
        FilePreviewPDFSizing.clampedSidebarWidth(
            proposedWidth,
            containerWidth: max(splitView.bounds.width, bounds.width),
            dividerThickness: splitView.dividerThickness,
            minimumWidth: minimumSidebarWidthForCurrentMode()
        )
    }

    private func minimumSidebarWidthForCurrentMode() -> CGFloat {
        switch sidebarMode {
        case .thumbnails:
            FilePreviewPDFSizing.minimumThumbnailSidebarWidth
        case .tableOfContents:
            Metrics.minimumSidebarWidth
        }
    }

    private func preferredSidebarWidthForCurrentMode() -> CGFloat {
        switch sidebarMode {
        case .thumbnails:
            thumbnailView.preferredSidebarWidth()
        case .tableOfContents:
            FilePreviewPDFSizing.preferredOutlineSidebarWidth(for: outlineRoot)
        }
    }

    private func logSidebarWidth(
        reason: String,
        proposed: CGFloat? = nil,
        applied: CGFloat? = nil
    ) {
        #if DEBUG
        let mode = sidebarMode == .tableOfContents ? "toc" : "thumbnails"
        let currentWidth = sidebarHost.frame.width
        let preferredWidth = preferredSidebarWidthForCurrentMode()
        let thumbnailWidth = thumbnailView.preferredSidebarWidth()
        let tocWidth = FilePreviewPDFSizing.preferredOutlineSidebarWidth(for: outlineRoot)
        cmuxDebugLog(
            "filePreview.pdf.sidebarWidth reason=\(reason) mode=\(mode) " +
            "current=\(formatSidebarWidth(currentWidth)) " +
            "proposed=\(formatSidebarWidth(proposed)) " +
            "applied=\(formatSidebarWidth(applied)) " +
            "preferred=\(formatSidebarWidth(preferredWidth)) " +
            "thumbnailPreferred=\(formatSidebarWidth(thumbnailWidth)) " +
            "tocPreferred=\(formatSidebarWidth(tocWidth)) " +
            "min=\(formatSidebarWidth(minimumSidebarWidthForCurrentMode())) " +
            "content=\(formatSidebarWidth(contentHost.frame.width))"
        )
        #endif
    }

    #if DEBUG
    private func formatSidebarWidth(_ width: CGFloat?) -> String {
        guard let width, width.isFinite else { return "nil" }
        return String(format: "%.1f", Double(width))
    }
    #endif

    private func applyPreferredSidebarWidthIfNeeded() {
        guard !didUserResizeSidebar,
              didSetInitialSidebarWidth,
              isSidebarVisible,
              !sidebarHost.isHidden else { return }
        let preferredWidth = preferredSidebarWidthForCurrentMode()
        guard abs(sidebarHost.frame.width - preferredWidth) > 0.5 else { return }
        logSidebarWidth(reason: "applyPreferred", proposed: preferredWidth)
        applySidebarWidth(preferredWidth)
    }

    private func applySidebarWidth(_ proposedWidth: CGFloat) {
        let width = clampedSidebarWidth(proposedWidth)
        lastSidebarWidth = width
        logSidebarWidth(reason: "applySidebarWidth", proposed: proposedWidth, applied: width)
        let applyWidth = {
            self.isApplyingSidebarWidth = true
            defer { self.isApplyingSidebarWidth = false }
            self.splitView.setPosition(width, ofDividerAt: 0)
            self.splitView.adjustSubviews()
            self.splitView.layoutSubtreeIfNeeded()
            self.layoutFloatingChrome()
        }

        applyPDFViewportChange(applyWidth)
    }

    private func applyPDFViewportChange(_ change: () -> Void) {
        guard pdfView.document != nil else {
            change()
            return
        }
        preserveVisiblePDFTop {
            change()
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    func splitViewWillResizeSubviews(_ notification: Notification) {
        guard !isApplyingSidebarWidth,
              isSidebarVisible,
              !sidebarHost.isHidden,
              pdfView.document != nil else { return }
        pdfResizeSequence += 1
        activePDFResizeID = pdfResizeSequence
        preparePDFViewportSnapshot()
        pendingSidebarResizeSnapshot = FilePreviewPDFViewportSnapshot.capture(
            in: pdfView,
            scrollView: pdfScrollView(),
            anchor: .top
        )
        logPDFResizeProbe(
            "will id=\(activePDFResizeID ?? -1) event=\(debugEventType()) " +
            "snapshot=\(debugSnapshot(pendingSidebarResizeSnapshot)) \(pdfDebugState())"
        )
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isSidebarVisible, !sidebarHost.isHidden else { return }
        let sidebarWidth = sidebarHost.frame.width
        guard sidebarWidth >= minimumSidebarWidthForCurrentMode() else { return }
        logSidebarWidth(reason: "splitViewDidResize", applied: sidebarWidth)
        guard !isApplyingSidebarWidth else { return }
        let resizeID: Int
        if let activePDFResizeID {
            resizeID = activePDFResizeID
        } else {
            pdfResizeSequence += 1
            resizeID = pdfResizeSequence
            self.activePDFResizeID = resizeID
        }
        logPDFResizeProbe(
            "did.begin id=\(resizeID) event=\(debugEventType()) " +
            "snapshot=\(debugSnapshot(pendingSidebarResizeSnapshot)) \(pdfDebugState())"
        )
        if NSApp.currentEvent?.type == .leftMouseDragged {
            didUserResizeSidebar = true
        }
        lastSidebarWidth = sidebarWidth
        layoutFloatingChrome()
        let resizeSnapshot = pendingSidebarResizeSnapshot
        pendingSidebarResizeSnapshot = nil
        withSuppressedPDFPageChangeNotifications {
            if let resizeSnapshot {
                refreshPDFSmartFitWithoutViewportRestore()
                resizeSnapshot.restore(in: pdfView, scrollView: pdfScrollView())
            } else {
                refreshPDFSmartFitPreservingVisibleTop()
            }
        }
        logPDFResizeProbe("did.end id=\(resizeID) \(pdfDebugState())")
        activePDFResizeID = nil
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        minimumSidebarWidthForCurrentMode()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        clampedSidebarWidth(Metrics.maximumSidebarWidth)
    }

    private func updateSidebarContent() {
        let showingThumbnails = sidebarMode == .thumbnails
        let showingTableOfContents = sidebarMode == .tableOfContents
        let hasOutline = (outlineRoot?.numberOfChildren ?? 0) > 0
        thumbnailView.isHidden = !showingThumbnails
        outlineScrollView.isHidden = !showingTableOfContents || !hasOutline
        outlinePlaceholder.isHidden = !showingTableOfContents || hasOutline
    }

    private func applyDisplayMode() {
        switch displayMode {
        case .continuousScroll:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        case .singlePage:
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .vertical
        case .twoPages:
            pdfView.displayMode = .twoUp
            pdfView.displayDirection = .horizontal
        }
        pdfView.autoScales = true
        updatePDFScrollObserver()
        refreshPDFSmartFitPreservingVisibleTop()
    }

    private func refreshPDFSmartFitWithoutViewportRestore() {
        guard pdfView.document != nil, pdfView.autoScales else { return }
        logPDFResizeProbe("smartFit.begin \(pdfDebugState())")
        contentHost.layoutSubtreeIfNeeded()
        pdfView.layoutSubtreeIfNeeded()
        pdfView.autoScales = false
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
        updatePDFScrollObserver()
        logPDFResizeProbe("smartFit.end \(pdfDebugState())")
    }

    private func refreshPDFSmartFitPreservingVisibleTop() {
        preserveVisiblePDFTop {
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    private func refreshPDFSmartFitPreservingVisibleCenter() {
        preserveVisiblePDFCenter {
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    private func zoomPDF(with event: NSEvent, factor: CGFloat) {
        guard pdfView.document != nil else { return }
        guard factor.isFinite, factor > 0 else { return }
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor * factor, preservingVisibleCenter: true)
    }

    private func togglePDFSmartZoom() {
        if pdfView.autoScales {
            actualSize()
        } else {
            zoomToFit()
        }
    }

    private func rotatePDF(with event: NSEvent) {
        rotationAccumulator += CGFloat(event.rotation)
        if rotationAccumulator >= 45 {
            rotateCurrentPDFPage(by: -90)
            rotationAccumulator = 0
        } else if rotationAccumulator <= -45 {
            rotateCurrentPDFPage(by: 90)
            rotationAccumulator = 0
        }
    }

    private func swipePDF(with event: NSEvent) {
        if event.deltaX < 0 {
            navigatePDFPage(by: 1)
        } else if event.deltaX > 0 {
            navigatePDFPage(by: -1)
        }
    }

    private func navigatePDFPage(by delta: Int) {
        guard delta != 0,
              let document = pdfView.document,
              document.pageCount > 0 else { return }
        let currentPageIndex = visiblePDFPageIndex(for: document) ?? 0
        let nextPageIndex = min(max(currentPageIndex + delta, 0), document.pageCount - 1)
        guard nextPageIndex != currentPageIndex,
              let page = document.page(at: nextPageIndex) else { return }
        goToPDFPage(page)
    }

    private func goToPDFPage(_ page: PDFPage, scrollThumbnailToVisible: Bool = true) {
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0, pageIndex < document.pageCount else { return }
        withSuppressedPDFPageChangeNotifications {
            pdfView.go(to: page)
        }
        updatePageControls(
            pageIndexOverride: pageIndex,
            scrollThumbnailToVisible: scrollThumbnailToVisible
        )
    }

    private func rotateCurrentPDFPage(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        page.rotation = normalizedRotation(page.rotation + degrees)
        pdfView.layoutDocumentView()
        pdfView.setNeedsDisplay(pdfView.bounds)
        if let document = pdfView.document {
            pageRotationState.record(page: page, in: document, rotationBy: degrees)
            thumbnailView.reloadPage(at: document.index(for: page))
        }
    }

    private func setPDFScaleFactor(_ nextScale: CGFloat, preservingVisibleCenter: Bool = false) {
        let clamped = min(max(nextScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        guard clamped.isFinite else { return }
        if preservingVisibleCenter {
            preserveVisiblePDFCenter {
                pdfView.scaleFactor = clamped
            }
        } else {
            pdfView.scaleFactor = clamped
        }
    }

    private func preparePDFViewportSnapshot() {
        contentHost.layoutSubtreeIfNeeded()
        pdfView.layoutSubtreeIfNeeded()
    }

    private func preserveVisiblePDFTop(_ viewportChange: () -> Void) {
        preservePDFViewport(anchor: .top, viewportChange)
    }

    private func preserveVisiblePDFCenter(_ viewportChange: () -> Void) {
        preservePDFViewport(anchor: .center, viewportChange)
    }

    private func preservePDFViewport(
        anchor: FilePreviewPDFViewportAnchor,
        _ viewportChange: () -> Void
    ) {
        preparePDFViewportSnapshot()
        guard let snapshot = FilePreviewPDFViewportSnapshot.capture(
            in: pdfView,
            scrollView: pdfScrollView(),
            anchor: anchor
        ) else {
            logPDFResizeProbe("preserve.noSnapshot anchor=\(debugAnchor(anchor)) \(pdfDebugState())")
            viewportChange()
            return
        }
        logPDFResizeProbe(
            "preserve.begin anchor=\(debugAnchor(anchor)) snapshot=\(debugSnapshot(snapshot)) \(pdfDebugState())"
        )
        withSuppressedPDFPageChangeNotifications {
            viewportChange()
            snapshot.restore(in: pdfView, scrollView: pdfScrollView())
        }
        logPDFResizeProbe("preserve.end anchor=\(debugAnchor(anchor)) \(pdfDebugState())")
    }

    private func withSuppressedPDFPageChangeNotifications(_ body: () -> Void) {
        let previousValue = suppressPDFPageChangeNotifications
        suppressPDFPageChangeNotifications = true
        defer { suppressPDFPageChangeNotifications = previousValue }
        body()
    }

    private func registerFocusEndpoint() {
        panel?.attachPreviewFocus(root: pdfView, primaryResponder: pdfView, intent: .pdfCanvas)
        panel?.attachPreviewFocus(
            root: thumbnailView,
            primaryResponder: thumbnailView.focusResponder(),
            intent: .pdfThumbnails
        )
        panel?.attachPreviewFocus(root: outlineView, primaryResponder: outlineView, intent: .pdfOutline)
    }

    private func setActivePDFRegion(_ region: FilePreviewPanelFocusIntent?) {
        guard activePDFRegion != region else { return }
        activePDFRegion = region
        thumbnailView.setSelectionActive(region == .pdfThumbnails)
        guard let region else { return }
        panel?.noteFilePreviewFocusIntent(region)
        AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: window)
    }

    private func updatePDFThumbnailSelectionFocus() {
        setActivePDFRegion(currentPDFFocusRegion())
    }

    private func updatePDFScrollObserver() {
        guard let clipView = pdfScrollView()?.contentView else { return }
        guard observedPDFClipView !== clipView else { return }
        removePDFScrollObserver()
        observedPDFClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfClipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func removePDFScrollObserver() {
        if let observedPDFClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedPDFClipView
            )
        }
        observedPDFClipView = nil
    }

    private func currentPDFFocusRegion() -> FilePreviewPanelFocusIntent? {
        guard window?.isKeyWindow == true,
              !isHiddenOrHasHiddenAncestor,
              let intent = panel?.currentFilePreviewFocusIntent(in: window) else { return nil }
        switch intent {
        case .pdfCanvas, .pdfThumbnails, .pdfOutline:
            return intent
        case .textEditor, .imageCanvas, .mediaPlayer, .quickLook:
            return nil
        }
    }

    #if DEBUG
    private func logPDFResizeProbe(_ message: @autoclosure () -> String) {
        cmuxDebugLog("filePreview.pdf.resize \(message())")
    }

    private func pdfDebugState() -> String {
        let document = pdfView.document
        let pageDescription: String
        if let document, let currentPage = pdfView.currentPage {
            let pageIndex = document.index(for: currentPage)
            pageDescription = pageIndex >= 0 ? "\(pageIndex + 1)/\(document.pageCount)" : "unknown/\(document.pageCount)"
        } else if let document {
            pageDescription = "nil/\(document.pageCount)"
        } else {
            pageDescription = "nil"
        }
        let topPageDescription: String
        if let document, let topPage = topVisiblePDFPage() {
            let pageIndex = document.index(for: topPage)
            topPageDescription = pageIndex >= 0 ? "\(pageIndex + 1)/\(document.pageCount)" : "unknown/\(document.pageCount)"
        } else {
            topPageDescription = "nil"
        }
        let scrollView = pdfScrollView()
        let clipBounds = scrollView?.contentView.bounds
        let documentBounds = scrollView?.documentView?.bounds
        return "mode=\(sidebarMode == .tableOfContents ? "toc" : "thumbs") " +
            "visible=\(isSidebarVisible ? 1 : 0) " +
            "sidebar=\(debugNumber(sidebarHost.frame.width)) " +
            "content=\(debugNumber(contentHost.frame.width)) " +
            "auto=\(pdfView.autoScales ? 1 : 0) " +
            "scale=\(debugNumber(pdfView.scaleFactor)) " +
            "page=\(pageDescription) " +
            "topPage=\(topPageDescription) " +
            "clip=\(debugRect(clipBounds)) " +
            "doc=\(debugRect(documentBounds))"
    }

    private func debugSnapshot(_ snapshot: FilePreviewPDFViewportSnapshot?) -> String {
        snapshot == nil ? "nil" : "captured"
    }

    private func debugAnchor(_ anchor: FilePreviewPDFViewportAnchor) -> String {
        switch anchor {
        case .center:
            "center"
        case .top:
            "top"
        }
    }

    private func debugEventType() -> String {
        guard let event = NSApp.currentEvent else { return "nil" }
        return "\(event.type.rawValue)"
    }

    private func debugRect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "(\(debugNumber(rect.origin.x)),\(debugNumber(rect.origin.y)) " +
            "\(debugNumber(rect.width))x\(debugNumber(rect.height)))"
    }

    private func debugNumber(_ value: CGFloat) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.1f", Double(value))
    }
    #else
    private func logPDFResizeProbe(_ message: @autoclosure () -> String) {}

    private func pdfDebugState() -> String { "" }

    private func debugSnapshot(_ snapshot: FilePreviewPDFViewportSnapshot?) -> String { "" }

    private func debugAnchor(_ anchor: FilePreviewPDFViewportAnchor) -> String { "" }

    private func debugEventType() -> String { "" }
    #endif

    private func pdfScrollView() -> NSScrollView? {
        firstScrollView(in: pdfView)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let outline = item as? PDFOutline ?? outlineRoot
        return outline?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let outline = item as? PDFOutline else { return false }
        return outline.numberOfChildren > 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let outline = item as? PDFOutline ?? outlineRoot
        return outline?.child(at: index) ?? NSNull()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let outline = item as? PDFOutline else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("filePreviewPDFOutlineCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeOutlineCell(identifier: identifier)
        cell.textField?.stringValue = outline.label ?? ""
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        setActivePDFRegion(.pdfOutline)
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let outline = outlineView.item(atRow: selectedRow) as? PDFOutline,
              let destination = outline.destination,
              let page = destination.page else { return }
        goToPDFPage(page)
    }

    private func makeOutlineCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

final class FilePreviewImageContainerView: NSView {
    private let viewport = FilePreviewViewport()
    private let scrollView = FilePreviewImageScrollView()
    private let documentView = FilePreviewImageDocumentView()
    private let chromeHost = FilePreviewPDFChromeHostingView()
    private weak var panel: FilePreviewPanel?
    private var currentURL: URL?
    private var currentRevision: Int?
    private var loadGeneration = 0
    private var pendingReloadAnchorRatio: CGPoint?
    private var pendingReloadWasFitMode: Bool?
    private var pendingReloadScale: CGFloat?
    private var pendingReloadRotationDegrees: Int?
    private var imageSize = CGSize(width: 1, height: 1)
    private var scale: CGFloat = 1
    private var isFitMode = true
    private var rotationDegrees = 0
    private var rotationAccumulator: CGFloat = 0
    private var previewBackgroundColor = NSColor.textBackgroundColor
    private var drawsPreviewBackground = true
    private let imageLoader = FilePreviewLatestLoadCoordinator<FilePreviewImageLoadResult>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerFocusEndpoint()
    }

    override func layout() {
        super.layout()
        applyBackgroundAppearance()
        if isFitMode {
            scale = fitScale()
        }
        applyScale()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            panel?.noteFilePreviewFocusIntent(.imageCanvas)
        }
        return accepted
    }

    func setPanel(_ panel: FilePreviewPanel) {
        self.panel = panel
        registerFocusEndpoint()
    }

    func close() {
        removeFromSuperview()
        documentView.imageView.image = nil
        currentURL = nil
        currentRevision = nil
        loadGeneration &+= 1
        imageLoader.cancel()
        clearPendingReloadState()
        panel = nil
    }

    func setBackgroundAppearance(backgroundColor: NSColor, drawsBackground: Bool) {
        guard previewBackgroundColor != backgroundColor || drawsPreviewBackground != drawsBackground else { return }
        previewBackgroundColor = backgroundColor
        drawsPreviewBackground = drawsBackground
        applyBackgroundAppearance()
    }

    func setURL(_ url: URL, revision: Int) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        guard currentURL != url || currentRevision != revision else { return }
        let isReload = currentURL == url
        if isReload, pendingReloadAnchorRatio == nil {
            captureReloadState()
        }
        currentURL = url
        currentRevision = revision
        loadGeneration &+= 1
        let generation = loadGeneration
        documentView.imageView.image = nil
        if !isReload {
            imageSize = normalizedSize(.zero)
            isFitMode = true
            rotationDegrees = 0
            rotationAccumulator = 0
            scale = fitScale()
            applyScale()
        }

        let loadURL = url
        imageLoader.submit(load: { await FilePreviewImageLoadResult.load(url: loadURL) }) { [weak self] result in
            guard let self,
                  self.currentURL == loadURL,
                  self.loadGeneration == generation else { return }
            self.applyLoadedImage(result.image)
        }
    }

    private func applyLoadedImage(_ image: NSImage?) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let reloadAnchorRatio = pendingReloadAnchorRatio
        let reloadWasFitMode = pendingReloadWasFitMode
        let reloadScale = pendingReloadScale
        let reloadRotationDegrees = pendingReloadRotationDegrees
        clearPendingReloadState()

        documentView.imageView.image = image
        imageSize = normalizedSize(image?.size ?? .zero)
        isFitMode = reloadWasFitMode ?? true
        rotationDegrees = reloadRotationDegrees ?? 0
        rotationAccumulator = 0
        scale = isFitMode ? fitScale() : (reloadScale ?? 1)
        applyScale()
        if let reloadAnchorRatio {
            restoreReloadAnchor(reloadAnchorRatio)
        }
    }

    private func captureReloadState() {
        let clipBounds = scrollView.contentView.bounds
        let documentBounds = documentView.bounds
        pendingReloadAnchorRatio = CGPoint(
            x: viewport.normalizedAnchorRatio(
                clipBounds.midX - documentBounds.minX,
                length: documentBounds.width
            ),
            y: viewport.normalizedAnchorRatio(
                clipBounds.midY - documentBounds.minY,
                length: documentBounds.height
            )
        )
        pendingReloadWasFitMode = isFitMode
        pendingReloadScale = scale
        pendingReloadRotationDegrees = rotationDegrees
    }

    private func restoreReloadAnchor(_ anchorRatio: CGPoint) {
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        let documentPoint = CGPoint(
            x: documentBounds.minX + (documentBounds.width * anchorRatio.x),
            y: documentBounds.minY + (documentBounds.height * anchorRatio.y)
        )
        let anchorOffset = CGPoint(x: clipView.bounds.width * 0.5, y: clipView.bounds.height * 0.5)
        let nextOrigin = viewport.clampedClipOrigin(
            documentPoint: documentPoint,
            anchorOffsetInClip: anchorOffset,
            documentBounds: documentBounds,
            clipSize: clipView.bounds.size
        )
        clipView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func clearPendingReloadState() {
        pendingReloadAnchorRatio = nil
        pendingReloadWasFitMode = nil
        pendingReloadScale = nil
        pendingReloadRotationDegrees = nil
    }

    private func registerFocusEndpoint() {
        panel?.attachPreviewFocus(root: self, primaryResponder: self, intent: .imageCanvas)
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false

        chromeHost.setContentView(FilePreviewPDFZoomChromeView(
            chromeStyleVariant: .liquidGlass,
            fileURL: nil,
            zoomOut: { [weak self] in self?.zoomOut() },
            actualSize: { [weak self] in self?.actualSize() },
            zoomIn: { [weak self] in self?.zoomIn() },
            zoomToFit: { [weak self] in self?.zoomToFit() },
            rotateLeft: { [weak self] in self?.rotateLeft() },
            rotateRight: { [weak self] in self?.rotateRight() },
            refresh: {}
        ))
        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        chromeHost.setContentHuggingPriority(.required, for: .horizontal)
        chromeHost.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        scrollView.onMagnify = { [weak self] event in
            let factor = 1.0 + event.magnification
            self?.zoomImage(with: event, factor: factor)
        }
        scrollView.onScrollZoom = { [weak self] event in
            self?.zoomImage(with: event, factor: FilePreviewInteraction.zoomFactor(forScroll: event))
        }
        scrollView.onSmartMagnify = { [weak self] event in
            self?.toggleImageSmartZoom(with: event)
        }
        scrollView.onRotate = { [weak self] event in
            self?.rotateImage(with: event)
        }
        documentView.onMagnify = { [weak self] event in
            let factor = 1.0 + event.magnification
            self?.zoomImage(with: event, factor: factor)
        }
        documentView.onSmartMagnify = { [weak self] event in
            self?.toggleImageSmartZoom(with: event)
        }
        documentView.onRotate = { [weak self] event in
            self?.rotateImage(with: event)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(chromeHost)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            chromeHost.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            chromeHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chromeHost.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            chromeHost.heightAnchor.constraint(equalToConstant: 40),
        ])
        applyBackgroundAppearance()
    }

    private func applyBackgroundAppearance() {
        let resolvedBackgroundColor = FilePreviewNativeBackground.resolvedColor(
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        FilePreviewNativeBackground.applyRootLayer(
            to: self,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        scrollView.drawsBackground = drawsPreviewBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsPreviewBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
    }

    @objc private func zoomOut() {
        isFitMode = false
        setImageScale(scale / FilePreviewInteraction.zoomStep, preservingVisibleCenter: true)
    }

    @objc private func zoomIn() {
        isFitMode = false
        setImageScale(scale * FilePreviewInteraction.zoomStep, preservingVisibleCenter: true)
    }

    @objc private func zoomToFit() {
        isFitMode = true
        scale = fitScale()
        applyScale()
    }

    @objc private func actualSize() {
        isFitMode = false
        setImageScale(1.0, preservingVisibleCenter: true)
    }

    @objc private func rotateLeft() {
        rotateImage(by: -90)
    }

    @objc private func rotateRight() {
        rotateImage(by: 90)
    }

    private func fitScale() -> CGFloat {
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 1, clipSize.height > 1 else { return scale }
        let imageSize = displayedImageSize()
        let widthScale = clipSize.width / max(imageSize.width, 1)
        let heightScale = clipSize.height / max(imageSize.height, 1)
        return clampedImageScale(min(widthScale, heightScale))
    }

    private func applyScale() {
        let imageSize = displayedImageSize()
        let scaledSize = CGSize(
            width: max(1, imageSize.width * scale),
            height: max(1, imageSize.height * scale)
        )
        let clipSize = scrollView.contentView.bounds.size
        documentView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(clipSize.width, scaledSize.width),
                height: max(clipSize.height, scaledSize.height)
            )
        )
        documentView.scaledImageSize = scaledSize
        documentView.rotationDegrees = rotationDegrees
        documentView.needsLayout = true
    }

    private func setImageScale(_ nextScale: CGFloat, preservingVisibleCenter: Bool = false) {
        let clamped = clampedImageScale(nextScale)
        guard clamped.isFinite else { return }
        if preservingVisibleCenter {
            preserveVisibleImageCenter {
                scale = clamped
                applyScale()
            }
        } else {
            scale = clamped
            applyScale()
        }
    }

    private func preserveVisibleImageCenter(_ scaleChange: () -> Void) {
        documentView.layoutSubtreeIfNeeded()
        let clipBounds = scrollView.contentView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else {
            scaleChange()
            return
        }

        let anchorInClip = CGPoint(x: clipBounds.midX, y: clipBounds.midY)
        let oldImageFrame = documentView.imageView.frame
        let anchorInDocument = documentView.convert(anchorInClip, from: scrollView.contentView)
        let anchorRatio = CGPoint(
            x: viewport.normalizedAnchorRatio(
                anchorInDocument.x - oldImageFrame.minX,
                length: oldImageFrame.width
            ),
            y: viewport.normalizedAnchorRatio(
                anchorInDocument.y - oldImageFrame.minY,
                length: oldImageFrame.height
            )
        )

        scaleChange()
        documentView.layoutSubtreeIfNeeded()

        let newImageFrame = documentView.imageView.frame
        let targetDocumentPoint = CGPoint(
            x: newImageFrame.minX + (newImageFrame.width * anchorRatio.x),
            y: newImageFrame.minY + (newImageFrame.height * anchorRatio.y)
        )
        scrollDocumentPoint(targetDocumentPoint, toClipPoint: anchorInClip)
    }

    private func zoomImage(with event: NSEvent, factor: CGFloat) {
        guard documentView.imageView.image != nil else { return }
        guard factor.isFinite, factor > 0 else { return }

        let anchorInClip = scrollView.contentView.convert(event.locationInWindow, from: nil)
        let oldImageFrame = documentView.imageView.frame
        let anchorInDocument = documentView.convert(event.locationInWindow, from: nil)
        let anchorRatio = CGPoint(
            x: normalizedAnchorRatio(
                anchorInDocument.x - oldImageFrame.minX,
                length: oldImageFrame.width
            ),
            y: normalizedAnchorRatio(
                anchorInDocument.y - oldImageFrame.minY,
                length: oldImageFrame.height
            )
        )

        isFitMode = false
        scale = clampedImageScale(scale * factor)
        applyScale()
        documentView.layoutSubtreeIfNeeded()

        let newImageFrame = documentView.imageView.frame
        let anchoredDocumentPoint = CGPoint(
            x: newImageFrame.minX + (newImageFrame.width * anchorRatio.x),
            y: newImageFrame.minY + (newImageFrame.height * anchorRatio.y)
        )
        scrollDocumentPoint(anchoredDocumentPoint, toClipPoint: anchorInClip)
    }

    private func toggleImageSmartZoom(with event: NSEvent) {
        guard documentView.imageView.image != nil else { return }
        if isFitMode {
            isFitMode = false
            scale = 1.0
            applyScale()
            documentView.layoutSubtreeIfNeeded()
            let anchorInClip = scrollView.contentView.convert(event.locationInWindow, from: nil)
            let anchorInDocument = documentView.convert(event.locationInWindow, from: nil)
            scrollDocumentPoint(anchorInDocument, toClipPoint: anchorInClip)
        } else {
            zoomToFit()
        }
    }

    private func rotateImage(with event: NSEvent) {
        rotationAccumulator += CGFloat(event.rotation)
        if rotationAccumulator >= 45 {
            rotateImage(by: -90)
            rotationAccumulator = 0
        } else if rotationAccumulator <= -45 {
            rotateImage(by: 90)
            rotationAccumulator = 0
        }
    }

    private func rotateImage(by degrees: Int) {
        rotationDegrees = normalizedRotation(rotationDegrees + degrees)
        if isFitMode {
            scale = fitScale()
        }
        applyScale()
    }

    private func scrollDocumentPoint(_ documentPoint: CGPoint, toClipPoint clipPoint: CGPoint) {
        let clipSize = scrollView.contentView.bounds.size
        let clipOrigin = scrollView.contentView.bounds.origin
        let anchorOffsetInClip = CGPoint(
            x: clipPoint.x - clipOrigin.x,
            y: clipPoint.y - clipOrigin.y
        )
        let documentSize = documentView.bounds.size
        let maxOrigin = CGPoint(
            x: max(0, documentSize.width - clipSize.width),
            y: max(0, documentSize.height - clipSize.height)
        )
        let nextOrigin = CGPoint(
            x: min(max(0, documentPoint.x - anchorOffsetInClip.x), maxOrigin.x),
            y: min(max(0, documentPoint.y - anchorOffsetInClip.y), maxOrigin.y)
        )
        scrollView.contentView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func normalizedAnchorRatio(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 1 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }

    private func clampedImageScale(_ nextScale: CGFloat) -> CGFloat {
        min(max(nextScale, 0.05), 16.0)
    }

    private func displayedImageSize() -> CGSize {
        if abs(rotationDegrees) % 180 == 90 {
            return CGSize(width: imageSize.height, height: imageSize.width)
        }
        return imageSize
    }

    private func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    private func normalizedSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width), height: max(1, size.height))
    }
}

private final class FilePreviewImageScrollView: NSScrollView {
    var onMagnify: ((NSEvent) -> Void)?
    var onScrollZoom: ((NSEvent) -> Void)?
    var onSmartMagnify: ((NSEvent) -> Void)?
    var onRotate: ((NSEvent) -> Void)?
    private var panStartClipPoint: CGPoint?
    private var panStartDocumentOrigin: CGPoint?
    private var hasPushedPanCursor = false

    override var acceptsFirstResponder: Bool { true }

    override func magnify(with event: NSEvent) {
        if let onMagnify {
            onMagnify(event)
        } else {
            super.magnify(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if FilePreviewInteraction.hasZoomModifier(event), let onScrollZoom {
            onScrollZoom(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify {
            onSmartMagnify(event)
        } else {
            super.smartMagnify(with: event)
        }
    }

    override func rotate(with event: NSEvent) {
        if let onRotate {
            onRotate(event)
        } else {
            super.rotate(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let onSmartMagnify {
            onSmartMagnify(event)
            return
        }
        panStartClipPoint = contentView.convert(event.locationInWindow, from: nil)
        panStartDocumentOrigin = contentView.bounds.origin
        NSCursor.closedHand.push()
        hasPushedPanCursor = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panStartClipPoint, let panStartDocumentOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let currentClipPoint = contentView.convert(event.locationInWindow, from: nil)
        let delta = CGPoint(
            x: currentClipPoint.x - panStartClipPoint.x,
            y: currentClipPoint.y - panStartClipPoint.y
        )
        scroll(toDocumentOrigin: CGPoint(
            x: panStartDocumentOrigin.x - delta.x,
            y: panStartDocumentOrigin.y - delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        endPan()
    }

    override func mouseExited(with event: NSEvent) {
        endPan()
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    private func scroll(toDocumentOrigin origin: CGPoint) {
        guard let documentView else { return }
        let clipSize = contentView.bounds.size
        let documentSize = documentView.bounds.size
        let maxOrigin = CGPoint(
            x: max(0, documentSize.width - clipSize.width),
            y: max(0, documentSize.height - clipSize.height)
        )
        let nextOrigin = CGPoint(
            x: min(max(0, origin.x), maxOrigin.x),
            y: min(max(0, origin.y), maxOrigin.y)
        )
        contentView.scroll(to: nextOrigin)
        reflectScrolledClipView(contentView)
    }

    private func endPan() {
        panStartClipPoint = nil
        panStartDocumentOrigin = nil
        if hasPushedPanCursor {
            NSCursor.pop()
            hasPushedPanCursor = false
        }
    }
}

private final class FilePreviewImageDocumentView: NSView {
    let imageView = FilePreviewMagnifyingImageView()
    var scaledImageSize = CGSize(width: 1, height: 1)
    var rotationDegrees = 0 {
        didSet {
            imageView.rotationDegrees = rotationDegrees
        }
    }
    var onMagnify: ((NSEvent) -> Void)? {
        didSet {
            imageView.onMagnify = onMagnify
        }
    }
    var onSmartMagnify: ((NSEvent) -> Void)? {
        didSet {
            imageView.onSmartMagnify = onSmartMagnify
        }
    }
    var onRotate: ((NSEvent) -> Void)? {
        didSet {
            imageView.onRotate = onRotate
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        imageView.frame = CGRect(
            x: max(0, (bounds.width - scaledImageSize.width) * 0.5),
            y: max(0, (bounds.height - scaledImageSize.height) * 0.5),
            width: scaledImageSize.width,
            height: scaledImageSize.height
        )
    }

    override func magnify(with event: NSEvent) {
        if let onMagnify {
            onMagnify(event)
        } else {
            super.magnify(with: event)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify {
            onSmartMagnify(event)
        } else {
            super.smartMagnify(with: event)
        }
    }

    override func rotate(with event: NSEvent) {
        if let onRotate {
            onRotate(event)
        } else {
            super.rotate(with: event)
        }
    }
}

private final class FilePreviewMagnifyingImageView: NSImageView {
    var onMagnify: ((NSEvent) -> Void)?
    var onSmartMagnify: ((NSEvent) -> Void)?
    var onRotate: ((NSEvent) -> Void)?
    var rotationDegrees = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        if let onMagnify {
            onMagnify(event)
        } else {
            super.magnify(with: event)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify {
            onSmartMagnify(event)
        } else {
            super.smartMagnify(with: event)
        }
    }

    override func rotate(with event: NSEvent) {
        if let onRotate {
            onRotate(event)
        } else {
            super.rotate(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        guard let image, rotationDegrees != 0 else {
            super.draw(dirtyRect)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: CGFloat(rotationDegrees))
        transform.concat()

        let drawSize = rotatedDrawSize(for: image.size)
        let drawRect = CGRect(
            x: -drawSize.width * 0.5,
            y: -drawSize.height * 0.5,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func rotatedDrawSize(for imageSize: CGSize) -> CGSize {
        let availableSize: CGSize
        if abs(rotationDegrees) % 180 == 90 {
            availableSize = CGSize(width: bounds.height, height: bounds.width)
        } else {
            availableSize = bounds.size
        }
        let scale = min(
            availableSize.width / max(imageSize.width, 1),
            availableSize.height / max(imageSize.height, 1)
        )
        return CGSize(
            width: max(1, imageSize.width * scale),
            height: max(1, imageSize.height * scale)
        )
    }
}

private final class FilePreviewPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  !self.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.onPointerDown?()
                }
            }
            return event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
