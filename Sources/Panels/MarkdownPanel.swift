import AppKit
import CmuxFoundation
import Combine
import Foundation

enum MarkdownPanelDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
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

    /// Absolute path to the markdown file being displayed. Re-pointed in
    /// place when a Notes-tree move/rename relocates the file (or a folder
    /// above it) so open viewers follow instead of going "File unavailable".
    var filePath: String

    /// Project-scoped note slug when this Markdown panel was opened through
    /// the note surface path. Plain Markdown panels never infer this from path.
    var noteSlug: String?
    var noteID: String?
    var noteBodyPath: String?
    var noteTitle: String?

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published var content: String = ""

    /// Current raw text shown by the TextEdit mode.
    @Published var textContent: String = ""

    /// Whether TextEdit mode has unsaved changes.
    @Published var isDirty: Bool = false

    /// Whether TextEdit mode is saving to disk.
    @Published var isSaving: Bool = false

    /// The current view mode for this markdown panel. New panels default to preview.
    @Published var displayMode: MarkdownPanelDisplayMode = .preview

    /// Title shown in the tab bar (filename).
    @Published var displayTitle: String = ""

    /// SF Symbol icon for the tab bar. Matches the "New Note" toolbar action
    /// (`doc.text`) and text-file previews so notes read as plain documents
    /// rather than rich-text files.
    var displayIcon: String? { "doc.text" }

    /// Whether the file has been deleted or is unreadable.
    @Published var isFileUnavailable: Bool = false

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

    // MARK: - File watching

    // Watches `filePath` (file + ancestor-directory recovery) via CmuxFileWatch.
    private var fileWatcher: FileWatcher?
    private var fileWatchTask: Task<Void, Never>?
    var originalTextContent: String = ""
    var textEncoding: String.Encoding = .utf8
    var saveGeneration: Int = 0
    var activeSaveGeneration: Int?
    var autoSaveTask: Task<Void, Never>?
    /// The in-flight write started by `saveTextContent`, kept so the close
    /// path can order a final flush after it without depending on this
    /// panel staying alive.
    var activeSaveTask: Task<Void, Never>?
    /// True when the file lives in a `.cmux/notes` tree — the per-workspace
    /// Notes filesystem. Classified by path so every entrypoint (Notes tab,
    /// session restore, file explorer) gives the same note behavior. Lazy:
    /// `filePath` is immutable and this is consulted on every keystroke via
    /// the autosave scheduler.
    private(set) lazy var isWorkspaceNotesFile: Bool = Self.isWorkspaceNotesPath(filePath)
    /// Debounce clock for note autosave; sleeping on it cancels with the task.
    let autoSaveClock = ContinuousClock()
    var pendingSearchNeedle: String?
    var pendingShowFindInterface = false
    var pendingTextViewFocus = false
    weak var textView: NSTextView?
    var isClosed: Bool = false
    // NotificationCenter tokens; removal is thread-safe so deinit can drop them.
    private nonisolated(unsafe) var typographyDefaultsObserver: NSObjectProtocol?
    nonisolated(unsafe) var relocationObserver: NSObjectProtocol?
    nonisolated(unsafe) var retitleObserver: NSObjectProtocol?
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

        // An empty workspace note opens straight in the text editor: a new
        // note is opened to be written, and an empty render is useless. This
        // is the default for every entry point (Notes tree, pane drop,
        // restore); non-empty notes open in the rendered viewer like any md.
        // `loadFileContent()` reads the file just below, so `content.isEmpty`
        // already captures the empty-file case without a redundant `stat`.
        loadFileContent()
        if Self.isWorkspaceNotesPath(filePath), content.isEmpty {
            self.displayMode = .text
        }
        startWatching()
        observeTypographyDefaults()
        observeNoteRelocations()
        observeNoteRetitles()
    }

    /// Follow Notes-tree moves/renames so a panel open on the relocated file
    /// (or on a file inside a relocated folder) keeps working at the new path.
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
        guard displayMode == .text else { return }
        guard let textView, let window = textView.window else {
            pendingTextViewFocus = true
            return
        }
        let didFocus = window.makeFirstResponder(textView)
        pendingTextViewFocus = !didFocus
        if didFocus {
            applyPendingSearchNeedleIfPossible()
        }
    }

    func unfocus() {
        pendingTextViewFocus = false
    }

    func close() {
        isClosed = true
        autoSaveTask?.cancel()
        autoSaveTask = nil
        // Notes have no manual Save and the debounced autosave may not have fired
        // yet; flush pending edits before teardown. saveTextContent reads the live
        // textView, so flush before clearing it; the write Task captures content by
        // value and completes even as this panel is released.
        if behavesAsNote, isDirty {
            if saveTextContent() == nil, isSaving {
                // An older snapshot is mid-write and saveTextContent no-ops
                // while saving. Once this panel is released its completion
                // can't re-flush (weak self), so order a final write of the
                // newest text after the in-flight one, independent of this
                // panel's lifetime.
                let fileURL = URL(fileURLWithPath: filePath)
                let encoding = textEncoding
                let finalContent = textView?.string ?? textContent
                let inFlight = activeSaveTask
                let requiresTrustedNoteWrite = behavesAsNote
                Task.detached(priority: .utility) {
                    _ = await inFlight?.value
                    if requiresTrustedNoteWrite {
                        _ = await FilePreviewTextSaver.saveTrustedWorkspaceNote(
                            content: finalContent, to: fileURL, encoding: encoding
                        )
                    } else {
                        _ = await FilePreviewTextSaver.save(
                            content: finalContent, to: fileURL, encoding: encoding
                        )
                    }
                }
            }
        }
        rendererSession.close()
        GlobalSearchCoordinator.shared.purgePanel(id: id)
        textView = nil
        stopWatching()
        if let typographyDefaultsObserver {
            NotificationCenter.default.removeObserver(typographyDefaultsObserver)
            self.typographyDefaultsObserver = nil
        }
        if let relocationObserver {
            NotificationCenter.default.removeObserver(relocationObserver)
            self.relocationObserver = nil
        }
        if let retitleObserver {
            NotificationCenter.default.removeObserver(retitleObserver)
            self.retitleObserver = nil
        }
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }


    // MARK: - File I/O

    func loadFileContent(replacingDirtyContent: Bool = true) {
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

    func applyPendingSearchNeedleIfPossible() {
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
    func startWatching() {
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
        if let relocationObserver {
            NotificationCenter.default.removeObserver(relocationObserver)
        }
        if let retitleObserver {
            NotificationCenter.default.removeObserver(retitleObserver)
        }
    }
}

extension Notification.Name {
    /// Posted by ``NotesTreeStore`` after a move/rename relocates a note file
    /// or folder on disk. `userInfo`: `oldPath` / `newPath` as standardized
    /// absolute paths; a folder relocation implies every path beneath it.
    static let cmuxNoteFileRelocated = Notification.Name("cmuxNoteFileRelocated")
    /// Posted by ``NotesTreeStore`` after an index-owned flat note is renamed
    /// (its record retitled; the body file stays put). `userInfo`: `bodyPath`
    /// (standardized absolute body path) and `title` (the new display title).
    static let cmuxNoteRetitled = Notification.Name("cmuxNoteRetitled")
}
