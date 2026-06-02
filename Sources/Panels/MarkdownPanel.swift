import AppKit
import Combine
import CoreText
import Foundation

enum MarkdownPanelDisplayMode: String, CaseIterable, Identifiable {
    case preview
    case text

    var id: String { rawValue }
}

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject, FilePreviewTextEditingPanel {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

    /// Current raw text shown by the TextEdit mode.
    @Published private(set) var textContent: String = ""

    /// Whether TextEdit mode has unsaved changes.
    @Published private(set) var isDirty: Bool = false

    /// Whether TextEdit mode is saving to disk.
    @Published private(set) var isSaving: Bool = false

    /// The current view mode for this markdown panel. New panels default to preview.
    @Published private(set) var displayMode: MarkdownPanelDisplayMode = .preview

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.richtext" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Body font size for the preview renderer, in points. Drives the
    /// WKWebView `pageZoom` so `--font-size` and Cmd-+/Cmd-- scale the rendered
    /// document the way browser zoom scales a browser surface. Per-panel and
    /// transient; the persistent default lives in `MarkdownFontSizeSettings`.
    @Published private(set) var fontSize: Double

    /// Body prose font family for the preview renderer, as an installed
    /// font-family name. Empty string means the System default (the GitHub
    /// stack). Applied as an inline `font-family` on the rendered content; code
    /// blocks stay monospace. Per-panel; the persistent default lives in
    /// `MarkdownFontFamily`.
    @Published private(set) var fontFamily: String

    /// Stable markdown renderer state. Keep this panel-owned so split/tab
    /// layout churn does not recreate the WKWebView and flash existing content.
    let rendererSession = MarkdownRendererSession()

    // MARK: - File watching

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var directoryWatchSource: DispatchSourceFileSystemObject?
    private var directoryWatchPath: String?
    private var originalTextContent: String = ""
    private var textEncoding: String.Encoding = .utf8
    private var saveGeneration: Int = 0
    private var activeSaveGeneration: Int?
    private var pendingSearchNeedle: String?
    private weak var textView: NSTextView?
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.markdown-file-watch", qos: .utility)
    // NotificationCenter token; removal is thread-safe so deinit can drop it.
    private nonisolated(unsafe) var typographyDefaultsObserver: NSObjectProtocol?
    // The typography default this viewer is currently tracking. While the panel
    // still matches it, a default change (Set as Default / cmux.json reload) is
    // adopted; once the user customizes the panel it diverges and is left alone.
    private var followedFontSize: Double
    private var followedFontFamily: String

    // MARK: - Init

    /// - Parameter fontSize: Initial body font size in points. When `nil`, the
    ///   panel uses the persistent `markdown.fontSize` default. The value is
    ///   clamped to the supported range.
    init(workspaceId: UUID, filePath: String, fontSize: Double? = nil) {
        let defaultSize = MarkdownFontSizeSettings.resolvedDefault()
        let defaultFamily = MarkdownFontFamily.resolvedDefault()
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.fontSize = MarkdownFontSizeSettings.clamp(fontSize ?? defaultSize)
        self.fontFamily = defaultFamily
        self.followedFontSize = defaultSize
        self.followedFontFamily = defaultFamily
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        observeTypographyDefaults()
    }

    /// Adopt a changed typography default (from another viewer's "Set as Default"
    /// or a `cmux.json` reload), but only while this viewer still matches the
    /// default it was tracking — i.e. the user has not customized it.
    private func observeTypographyDefaults() {
        typographyDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adoptTypographyDefaultsIfFollowing()
            }
        }
    }

    private func adoptTypographyDefaultsIfFollowing() {
        guard !isClosed else { return }
        // Only viewers still tracking the default follow the change.
        guard abs(fontSize - followedFontSize) < 0.01, fontFamily == followedFontFamily else { return }
        let newSize = MarkdownFontSizeSettings.resolvedDefault()
        let newFamily = MarkdownFontFamily.resolvedDefault()
        _ = setFontSize(newSize)
        _ = setFontFamily(newFamily)
        followedFontSize = newSize
        followedFontFamily = newFamily
    }

    // MARK: - Font size / zoom

    /// Increases the preview font size by one step. Returns `true` if the size
    /// changed (so callers can beep when already at the maximum).
    @discardableResult
    func zoomIn() -> Bool {
        setFontSize(fontSize + MarkdownFontSizeSettings.stepPointSize)
    }

    /// Decreases the preview font size by one step. Returns `true` if the size
    /// changed (so callers can beep when already at the minimum).
    @discardableResult
    func zoomOut() -> Bool {
        setFontSize(fontSize - MarkdownFontSizeSettings.stepPointSize)
    }

    /// Resets the preview font size to the configured `markdown.fontSize`
    /// default. Returns `true` if the size changed.
    @discardableResult
    func resetZoom() -> Bool {
        setFontSize(MarkdownFontSizeSettings.resolvedDefault())
    }

    /// Sets the preview font size to an explicit point value (clamped). Used by
    /// the header font-size popover's manual entry. Returns `true` if changed.
    @discardableResult
    func setFontSize(_ candidate: Double) -> Bool {
        let clamped = MarkdownFontSizeSettings.clamp(candidate)
        guard abs(clamped - fontSize) > 0.0001 else { return false }
        fontSize = clamped
        return true
    }

    /// Sets the preview body prose font family (an installed font-family name,
    /// or empty for the System default). Returns `true` if changed.
    @discardableResult
    func setFontFamily(_ family: String) -> Bool {
        let normalized = MarkdownFontFamily.normalized(family)
        guard normalized != fontFamily else { return false }
        fontFamily = normalized
        return true
    }

    /// Resets both font size and family to the configured defaults. Used by the
    /// typography popover's "Reset to default" action.
    func resetTypography() {
        _ = setFontSize(MarkdownFontSizeSettings.resolvedDefault())
        _ = setFontFamily(MarkdownFontFamily.resolvedDefault())
    }

    // MARK: - Panel protocol

    func focus() {
        guard displayMode == .text else { return }
        _ = textView?.window?.makeFirstResponder(textView)
        applyPendingSearchNeedleIfPossible()
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        isClosed = true
        rendererSession.close()
        GlobalSearchCoordinator.shared.purgePanel(id: id)
        textView = nil
        stopWatching()
        if let typographyDefaultsObserver {
            NotificationCenter.default.removeObserver(typographyDefaultsObserver)
            self.typographyDefaultsObserver = nil
        }
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func setDisplayMode(_ mode: MarkdownPanelDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        if mode == .text {
            focus()
        }
    }

    func attachTextView(_ textView: NSTextView) {
        self.textView = textView
    }

    func retryPendingFocus() {
        focus()
    }

    func applySearchNeedle(_ needle: String) {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSearchNeedle = trimmed
        setDisplayMode(.text)
        applyPendingSearchNeedleIfPossible()
    }

    func updateTextContent(_ nextContent: String) {
        guard textContent != nextContent else { return }
        textContent = nextContent
        content = nextContent
        isDirty = nextContent != originalTextContent
        GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
    }

    @discardableResult
    func loadTextContent(replacingDirtyContent: Bool = true) -> Task<Void, Never>? {
        loadFileContent(replacingDirtyContent: replacingDirtyContent)
        return nil
    }

    @discardableResult
    func saveTextContent() -> Task<Void, Never>? {
        guard !isSaving else { return nil }
        let currentContent = textView?.string ?? textContent
        guard currentContent != originalTextContent else {
            textContent = currentContent
            content = currentContent
            isDirty = false
            GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
            return nil
        }

        saveGeneration += 1
        let generation = saveGeneration
        textContent = currentContent
        content = currentContent
        isDirty = true
        isSaving = true
        activeSaveGeneration = generation
        GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
        let fileURL = URL(fileURLWithPath: filePath)
        let encoding = textEncoding

        return Task { [weak self, currentContent, fileURL, encoding, generation] in
            let result = await FilePreviewTextSaver.save(content: currentContent, to: fileURL, encoding: encoding)
            guard let self, self.activeSaveGeneration == generation else { return }
            self.activeSaveGeneration = nil
            self.isSaving = false
            switch result {
            case .saved:
                self.originalTextContent = currentContent
                self.isDirty = self.textContent != currentContent
                self.isFileUnavailable = false
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
            case .failed(let fileExists):
                self.isFileUnavailable = !fileExists
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
            }
        }
    }

    // MARK: - File I/O

    private func loadFileContent(replacingDirtyContent: Bool = true) {
        switch Self.loadMarkdownFile(at: filePath) {
        case .loaded(let newContent, let encoding):
            applyLoadedContent(newContent, encoding: encoding, replacingDirtyContent: replacingDirtyContent)
        case .unavailable:
            guard replacingDirtyContent || !isDirty else {
                isFileUnavailable = true
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
                return
            }
            content = ""
            textContent = ""
            originalTextContent = ""
            isDirty = false
            isFileUnavailable = true
            GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
        }
    }

    private func applyLoadedContent(
        _ newContent: String,
        encoding: String.Encoding,
        replacingDirtyContent: Bool
    ) {
        if !replacingDirtyContent && isDirty {
            originalTextContent = newContent
            textEncoding = encoding
            isDirty = textContent != newContent
            isFileUnavailable = false
            GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
            return
        }

        content = newContent
        textContent = newContent
        originalTextContent = newContent
        textEncoding = encoding
        isDirty = false
        isFileUnavailable = false
        GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
    }

    private static func loadMarkdownFile(at path: String) -> FilePreviewTextLoader.Result {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .unavailable
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return .loaded(content: decoded, encoding: .utf8)
        }
        // Fallback: ISO Latin-1 accepts all 256 byte values and covers common
        // legacy encodings like Windows-1252 well enough for a raw editor.
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return .loaded(content: decoded, encoding: .isoLatin1)
        }
        return .unavailable
    }

    private func applyPendingSearchNeedleIfPossible() {
        guard let needle = pendingSearchNeedle,
              let textView else {
            return
        }

        let range = (textView.string as NSString).range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        guard range.location != NSNotFound else {
            pendingSearchNeedle = nil
            return
        }

        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        pendingSearchNeedle = nil
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        stopFileWatcher()

        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            startDirectoryWatcher()
            return
        }

        stopDirectoryWatcher()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was deleted or renamed. The old file descriptor points to
                // a stale inode, so we must always stop and reattach the watcher
                // even if the new file is already readable (atomic save case).
                DispatchQueue.main.async {
                    guard !self.isClosed else { return }
                    self.stopFileWatcher()
                    self.loadFileContent(replacingDirtyContent: false)
                    // Reattach to the replacement inode when atomic-save
                    // already created it; otherwise watch the directory until
                    // the file comes back.
                    self.startFileWatcher()
                }
            } else {
                // Content changed — reload.
                DispatchQueue.main.async {
                    guard !self.isClosed else { return }
                    self.loadFileContent(replacingDirtyContent: false)
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func startDirectoryWatcher() {
        for directoryPath in existingDirectoryCandidatesForWatcher() {
            if directoryWatchPath == directoryPath, directoryWatchSource != nil {
                return
            }

            let fd = open(directoryPath, O_EVTONLY)
            guard fd >= 0 else { continue }

            stopDirectoryWatcher()

            installDirectoryWatcher(fileDescriptor: fd, directoryPath: directoryPath)
            return
        }
    }

    private func installDirectoryWatcher(fileDescriptor fd: Int32, directoryPath: String) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if flags.contains(.delete) || flags.contains(.rename) {
                    // The watched directory inode changed. Drop the stale file
                    // descriptor before reattaching, even if the replacement is
                    // created at the same path string.
                    self.stopDirectoryWatcher()
                }
                self.loadFileContent(replacingDirtyContent: false)
                if !self.isFileUnavailable {
                    self.startFileWatcher()
                } else {
                    // If we were watching an ancestor, a child directory may
                    // have been recreated. Move the watcher as close to the
                    // target file as possible.
                    self.startDirectoryWatcher()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        directoryWatchSource = source
        directoryWatchPath = directoryPath
    }

    private func existingDirectoryCandidatesForWatcher() -> [String] {
        let fileManager = FileManager.default
        var current = (filePath as NSString).deletingLastPathComponent
        if current.isEmpty {
            current = fileManager.currentDirectoryPath
        }

        var candidates: [String] = []
        var seen = Set<String>()
        while !current.isEmpty {
            let standardized = (current as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { break }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
               isDirectory.boolValue {
                candidates.append(standardized)
            }

            let parent = (standardized as NSString).deletingLastPathComponent
            if parent == standardized || parent.isEmpty {
                break
            }
            current = parent
        }
        return candidates
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
    }

    private func stopDirectoryWatcher() {
        if let source = directoryWatchSource {
            source.cancel()
            directoryWatchSource = nil
        }
        directoryWatchPath = nil
    }

    private func stopWatching() {
        stopFileWatcher()
        stopDirectoryWatcher()
    }

    deinit {
        // DispatchSource cancel and removeObserver are safe from any thread.
        fileWatchSource?.cancel()
        directoryWatchSource?.cancel()
        if let typographyDefaultsObserver {
            NotificationCenter.default.removeObserver(typographyDefaultsObserver)
        }
    }
}

/// Persistent + per-panel font size for the markdown viewer.
///
/// The value is the `.markdown-body` font size in points. The web shell renders
/// the body at `baseRenderPointSize` px intrinsically, so the panel applies
/// `pointSize / baseRenderPointSize` as the WKWebView `pageZoom` to scale the
/// whole rendered document (text, code, tables, diagrams, images) the way
/// browser zoom does. Keep `baseRenderPointSize` in sync with the
/// `.markdown-body { font-size: … }` rule in `Resources/markdown-viewer/shell.html`.
enum MarkdownFontSizeSettings {
    /// UserDefaults / cmux.json key (`markdown.fontSize`).
    static let key = "markdown.fontSize"
    static let defaultPointSize: Double = 15
    static let minimumPointSize: Double = 8
    static let maximumPointSize: Double = 96
    static let stepPointSize: Double = 1
    /// Intrinsic `.markdown-body` font size baked into shell.html, in CSS px.
    static let baseRenderPointSize: Double = 15

    /// Clamps a requested point size into the supported range.
    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumPointSize), maximumPointSize)
    }

    /// The persistent default point size, honoring `markdown.fontSize` from
    /// UserDefaults / cmux.json and falling back to ``defaultPointSize``.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return defaultPointSize
        }
        return clamp(raw.doubleValue)
    }

    /// Persists `points` (clamped, rounded to integer points) as the default
    /// `markdown.fontSize` so new viewers start at this size. The Settings UI
    /// stepper and runtime both read the same key.
    static func setDefault(_ points: Double, defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(points).rounded()), forKey: key)
    }

    /// The WKWebView `pageZoom` factor that renders the body at `pointSize`.
    static func pageZoom(forPointSize pointSize: Double) -> CGFloat {
        CGFloat(clamp(pointSize) / baseRenderPointSize)
    }
}

/// Body prose font for the markdown viewer, chosen from the user's installed
/// fonts (including custom fonts).
///
/// The stored value is a font-family name; an empty string is the System
/// default (the GitHub stack), which clears the inline override. The chosen
/// family is applied as an inline `font-family` on the content element
/// (mirroring the theme injection). Code blocks keep their own monospace stack
/// from `github-markdown.css`.
enum MarkdownFontFamily {
    /// UserDefaults / cmux.json key (`markdown.fontFamily`).
    static let key = "markdown.fontFamily"
    /// Sentinel value for the System default (inherits the GitHub stack).
    static let systemDefault = ""

    /// Normalizes user/config input before persisting or applying it. Newlines
    /// collapse to spaces so a malformed cmux.json value cannot produce invalid
    /// multiline CSS.
    static func normalized(_ family: String) -> String {
        family
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The CSS `font-family` to apply, or `nil` for the System default. The
    /// family name is quoted so multi-word names resolve correctly.
    static func cssValue(for family: String) -> String? {
        let trimmed = normalized(family)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The persistent default font family, honoring `markdown.fontFamily` from
    /// UserDefaults / cmux.json and falling back to the System default.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> String {
        normalized(defaults.string(forKey: key) ?? systemDefault)
    }

    /// Persists `family` as the default `markdown.fontFamily` so new viewers
    /// start with it. An empty family removes the override.
    static func setDefault(_ family: String, defaults: UserDefaults = .standard) {
        let trimmed = normalized(family)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    private static let familyCache = MarkdownFontFamilyCache()

    /// Installed font families available to choose, sorted case-insensitively
    /// and excluding hidden (dot-prefixed) system fonts.
    ///
    /// Loaded off the main thread (font enumeration can take noticeable time on
    /// machines with many installed fonts) and cached, so the typography popover
    /// opens instantly and the list fills in shortly after.
    static func availableFamilies() async -> [String] {
        await familyCache.families()
    }
}

/// Loads and caches the installed font-family list off the main thread.
/// `CTFontManagerCopyAvailableFontFamilyNames` is thread-safe, unlike the
/// AppKit `NSFontManager` accessor.
private actor MarkdownFontFamilyCache {
    private var cached: [String]?

    func families() async -> [String] {
        if let cached { return cached }
        let names = await Task.detached(priority: .userInitiated) { () -> [String] in
            let raw = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
            return raw
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
        cached = names
        return names
    }
}

/// Writes the markdown viewer typography defaults (size + font).
///
/// Writing the keys triggers `UserDefaults.didChangeNotification`, which open
/// viewers observe: those still on the previous default adopt the new one, while
/// individually customized viewers keep their settings. The same path applies a
/// `markdown.*` change from `cmux.json` (the config file store writes the managed
/// values to `UserDefaults.standard`), so `cmux reload-config` refreshes open
/// viewers too.
enum MarkdownTypographyDefaults {
    static func setDefault(fontSize: Double, fontFamily: String, defaults: UserDefaults = .standard) {
        MarkdownFontSizeSettings.setDefault(fontSize, defaults: defaults)
        MarkdownFontFamily.setDefault(fontFamily, defaults: defaults)
    }
}
