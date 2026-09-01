import AppKit
import CmuxBrowser
import CmuxFoundation
import Combine
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
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
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

    /// Maximum width for the rendered markdown content column, in CSS pixels.
    /// Per-panel and transient; the persistent default lives in
    /// `MarkdownMaxWidthSettings`.
    @Published private(set) var maxContentWidth: Double

    /// Stable markdown renderer state. Keep this panel-owned so split/tab
    /// layout churn does not recreate the WKWebView and flash existing content.
    let rendererSession = MarkdownRendererSession()

    // MARK: - Find in preview

    /// Find-in-page state for the rendered preview. Non-nil when the find bar
    /// is visible. Uses the browser find machinery (`BrowserFindService` +
    /// `BrowserSearchOverlay`) against the preview WKWebView.
    @Published var searchState: BrowserSearchState? {
        didSet { handleSearchStateChange(oldValue: oldValue) }
    }

    /// Incremented whenever find focus ownership changes, so stale async
    /// focus requests posted before a hide/re-show can never steal focus.
    @Published private(set) var searchFocusRequestGeneration: UInt64 = 0

    private var searchNeedleCancellable: AnyCancellable?
    private var lastSearchNeedle = ""
    private lazy var findService = BrowserFindService(
        evaluator: MarkdownFindWebViewEvaluator(panel: self)
    )

    // MARK: - File watching

    // Watches `filePath` (file + ancestor-directory recovery) via CmuxFileWatch.
    private var fileWatcher: FileWatcher?
    private var fileWatchTask: Task<Void, Never>?
    private var originalTextContent: String = ""
    private var textEncoding: String.Encoding = .utf8
    private var saveGeneration: Int = 0
    private var activeSaveGeneration: Int?
    private var pendingSearchNeedle: String?
    /// Set when activation asks a preview panel to focus before SwiftUI has
    /// mounted its WKWebView. The renderer fulfills this at window attach.
    private var pendingPreviewFocus = false
    private weak var textView: NSTextView?
    private var isClosed: Bool = false
    // NotificationCenter token; removal is thread-safe so deinit can drop it.
    private nonisolated(unsafe) var typographyDefaultsObserver: NSObjectProtocol?
    // The typography default this viewer is currently tracking. While the panel
    // still matches it, a default change (Set as Default / cmux.json reload) is
    // adopted; once the user customizes the panel it diverges and is left alone.
    private var followedFontSize: Double
    private var followedFontFamily: String
    private var followedMaxContentWidth: Double

    // MARK: - Init

    /// - Parameter fontSize: Initial body font size in points. When `nil`, the
    ///   panel uses the persistent `markdown.fontSize` default. The value is
    ///   clamped to the supported range.
    init(workspaceId: UUID, filePath: String, fontSize: Double? = nil) {
        let defaultSize = MarkdownFontSizeSettings.resolvedDefault()
        let defaultFamily = MarkdownFontFamily.resolvedDefault()
        let defaultMaxWidth = MarkdownMaxWidthSettings.resolvedDefault()
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.fontSize = MarkdownFontSizeSettings.clamp(fontSize ?? defaultSize)
        self.fontFamily = defaultFamily
        self.maxContentWidth = defaultMaxWidth
        self.followedFontSize = defaultSize
        self.followedFontFamily = defaultFamily
        self.followedMaxContentWidth = defaultMaxWidth
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startWatching()
        observeTypographyDefaults()
        rendererSession.onMarkdownRendered = { [weak self] in
            self?.replayPendingPreviewFocusAfterWindowAttach()
            self?.replayActiveFindAfterRender()
        }
    }

    // MARK: - Find in preview (methods)

    /// Shows (or refocuses) the preview find bar. Preview-only: text mode uses
    /// the NSTextView's native find panel via the responder chain.
    func startFind() {
        guard displayMode == .preview else { return }
        let created = searchState == nil
        let recoveredNeedle = created ? lastSearchNeedle : ""
        if created { searchState = BrowserSearchState(needle: recoveredNeedle) }
        let shouldSelectAll = created && !recoveredNeedle.isEmpty
        searchFocusRequestGeneration &+= 1
        let generation = searchFocusRequestGeneration
        postSearchFocusNotification(generation: generation, selectAll: shouldSelectAll)
        // Re-post once because the overlay mounts on the same runloop turn and
        // can miss the first notification.
        DispatchQueue.main.async { [weak self] in
            self?.postSearchFocusNotification(generation: generation, selectAll: shouldSelectAll)
        }
    }

    func findNext() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyFindMatchCount(await self.findService.next())
        }
    }

    func findPrevious() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyFindMatchCount(await self.findService.previous())
        }
    }

    func hideFind() {
        searchState = nil
    }

    /// Whether an async find-field focus request for `generation` may still
    /// be applied. Guards against focus theft after hide or a newer request.
    func canApplySearchFocusRequest(_ generation: UInt64) -> Bool {
        searchState != nil && generation == searchFocusRequestGeneration
    }

    private func postSearchFocusNotification(generation: UInt64, selectAll: Bool) {
        guard canApplySearchFocusRequest(generation) else { return }
        NotificationCenter.default.post(
            name: .browserSearchFocus,
            object: id,
            userInfo: [FindFocusNotificationKey.selectAll: selectAll]
        )
    }

    private func handleSearchStateChange(oldValue: BrowserSearchState?) {
        if let searchState {
            searchNeedleCancellable = searchState.$needle
                .removeDuplicates()
                .map { needle -> AnyPublisher<String, Never> in
                    // Search instantly for empty (clear) and 3+ character
                    // needles; debounce 1-2 character needles, which light up
                    // far too many matches to be useful while mid-word.
                    if needle.isEmpty || needle.count >= 3 {
                        return Just(needle).eraseToAnyPublisher()
                    }
                    return Just(needle)
                        .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                        .eraseToAnyPublisher()
                }
                .switchToLatest()
                .sink { [weak self] needle in
                    self?.executeFindSearch(needle)
                }
        } else if let oldValue {
            lastSearchNeedle = oldValue.needle
            searchNeedleCancellable = nil
            searchFocusRequestGeneration &+= 1
            executeFindClear()
        }
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
            self.applyFindMatchCount(await self.findService.search(needle: needle))
        }
    }

    private func executeFindClear() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.findService.clear()
        }
    }

    private func applyFindMatchCount(_ count: BrowserFindMatchCount?) {
        guard let count else { return }
        searchState?.total = count.total
        searchState?.selected = count.selected
    }

    /// A content re-render replaces the preview DOM, wiping `<mark>` find
    /// highlights. Re-run the active search so counts and highlights recover.
    private func replayActiveFindAfterRender() {
        guard let state = searchState, !state.needle.isEmpty else { return }
        state.selected = nil
        state.total = nil
        executeFindSearch(state.needle)
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
        guard abs(fontSize - followedFontSize) < 0.01,
              fontFamily == followedFontFamily,
              abs(maxContentWidth - followedMaxContentWidth) < 0.01 else { return }
        let newSize = MarkdownFontSizeSettings.resolvedDefault()
        let newFamily = MarkdownFontFamily.resolvedDefault()
        let newMaxWidth = MarkdownMaxWidthSettings.resolvedDefault()
        _ = setFontSize(newSize)
        _ = setFontFamily(newFamily)
        _ = setMaxContentWidth(newMaxWidth)
        followedFontSize = newSize
        followedFontFamily = newFamily
        followedMaxContentWidth = newMaxWidth
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

    /// Sets the rendered markdown content column max width, in CSS pixels.
    /// Returns `true` if changed.
    @discardableResult
    func setMaxContentWidth(_ candidate: Double) -> Bool {
        let clamped = MarkdownMaxWidthSettings.clamp(candidate)
        guard abs(clamped - maxContentWidth) > 0.0001 else { return false }
        maxContentWidth = clamped
        return true
    }

    /// Resets typography to the configured defaults. Used by the popover's
    /// "Reset to default" action.
    func resetTypography() {
        let defaultSize = MarkdownFontSizeSettings.resolvedDefault()
        let defaultFamily = MarkdownFontFamily.resolvedDefault()
        let defaultMaxWidth = MarkdownMaxWidthSettings.resolvedDefault()
        _ = setFontSize(defaultSize)
        _ = setFontFamily(defaultFamily)
        _ = setMaxContentWidth(defaultMaxWidth)
        followedFontSize = defaultSize
        followedFontFamily = defaultFamily
        followedMaxContentWidth = defaultMaxWidth
    }

    /// Clears persisted markdown typography defaults and resets this viewer to
    /// the built-in app defaults.
    func resetTypographyToBuiltInDefaults() {
        MarkdownTypographyDefaults.resetToBuiltInDefaults()
        _ = setFontSize(MarkdownFontSizeSettings.defaultPointSize)
        _ = setFontFamily(MarkdownFontFamily.systemDefault)
        _ = setMaxContentWidth(MarkdownMaxWidthSettings.defaultCSSPixels)
        followedFontSize = MarkdownFontSizeSettings.defaultPointSize
        followedFontFamily = MarkdownFontFamily.systemDefault
        followedMaxContentWidth = MarkdownMaxWidthSettings.defaultCSSPixels
    }

    // MARK: - Panel protocol

    func focus() {
        if displayMode == .text {
            pendingPreviewFocus = false
            _ = textView?.window?.makeFirstResponder(textView)
            applyPendingSearchNeedleIfPossible()
            return
        }
        // Preview mode: the rendered web view is the panel's keyboard
        // surface. Taking first responder on activation is what moves the
        // keyboard out of wherever it was (for example the right-sidebar
        // file list after a click- or drag-open), so the find/shortcut
        // router targets this panel — the same behavior terminal and
        // browser panels have. No-op while the web view is not mounted;
        // the drop/open paths also hand off focus at the coordinator level.
        guard let webView = rendererSession.webView, let window = webView.window else {
            pendingPreviewFocus = true
            return
        }
        let didBecomeFirstResponder = window.makeFirstResponder(webView)
            && window.firstResponder === webView
        pendingPreviewFocus = !didBecomeFirstResponder
    }

    /// Completes a preview focus request recorded before the renderer view was
    /// attached to its window. The callback is event-driven, so it cannot
    /// steal focus after this panel has been unfocused in the meantime.
    func replayPendingPreviewFocusAfterWindowAttach() {
        guard pendingPreviewFocus, displayMode == .preview else { return }
        focus()
    }

    func unfocus() {
        pendingPreviewFocus = false
    }

    func close() {
        isClosed = true
        pendingPreviewFocus = false
        searchState = nil
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
            // The find bar and its highlights belong to the preview surface;
            // text mode has the NSTextView's native find panel instead.
            hideFind()
            focus()
        }
    }

    /// Re-reads the file without discarding an unsaved TextEdit buffer.
    func reloadFromDisk() {
        loadFileContent(replacingDirtyContent: false)
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

    // MARK: - File watcher

    /// Watches ``filePath`` for changes via ``CmuxFileWatch/FileWatcher``, which
    /// handles inode reattachment and nearest-existing-ancestor recovery
    /// internally; each change reloads the content.
    private func startWatching() {
        stopWatching()
        let watcher = FileWatcher(path: filePath)
        fileWatcher = watcher
        let events = watcher.events
        fileWatchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self, !self.isClosed else { break }
                self.loadFileContent(replacingDirtyContent: false)
            }
        }
    }

    private func stopWatching() {
        fileWatchTask?.cancel()
        fileWatchTask = nil
        // Dropping the watcher runs its deinit, cancelling the DispatchSources.
        fileWatcher = nil
    }

    deinit {
        fileWatchTask?.cancel()
        if let typographyDefaultsObserver {
            NotificationCenter.default.removeObserver(typographyDefaultsObserver)
        }
    }
}
