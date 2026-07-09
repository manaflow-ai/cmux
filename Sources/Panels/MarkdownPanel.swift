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
    private(set) var filePath: String

    /// Project-scoped note slug when this Markdown panel was opened through
    /// the note surface path. Plain Markdown panels never infer this from path.
    private(set) var noteSlug: String?
    private(set) var noteID: String?
    private(set) var noteBodyPath: String?
    private(set) var noteTitle: String?

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

    /// SF Symbol icon for the tab bar. Matches the "New Note" toolbar action
    /// (`doc.text`) and text-file previews so notes read as plain documents
    /// rather than rich-text files.
    var displayIcon: String? { "doc.text" }

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

    // MARK: - File watching

    // Watches `filePath` (file + ancestor-directory recovery) via CmuxFileWatch.
    private var fileWatcher: FileWatcher?
    private var fileWatchTask: Task<Void, Never>?
    private var originalTextContent: String = ""
    private var textEncoding: String.Encoding = .utf8
    private var saveGeneration: Int = 0
    private var activeSaveGeneration: Int?
    private var autoSaveTask: Task<Void, Never>?
    /// The in-flight write started by `saveTextContent`, kept so the close
    /// path can order a final flush after it without depending on this
    /// panel staying alive.
    private var activeSaveTask: Task<Void, Never>?
    private var pendingSearchNeedle: String?
    private var pendingShowFindInterface = false
    private var pendingTextViewFocus = false
    private weak var textView: NSTextView?
    private var isClosed: Bool = false
    // NotificationCenter tokens; removal is thread-safe so deinit can drop them.
    private nonisolated(unsafe) var typographyDefaultsObserver: NSObjectProtocol?
    private nonisolated(unsafe) var relocationObserver: NSObjectProtocol?
    private nonisolated(unsafe) var retitleObserver: NSObjectProtocol?
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
    private func observeNoteRelocations() {
        relocationObserver = NotificationCenter.default.addObserver(
            forName: .cmuxNoteFileRelocated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let oldPath = notification.userInfo?["oldPath"] as? String,
                  let newPath = notification.userInfo?["newPath"] as? String else { return }
            Task { @MainActor in
                self?.followRelocation(from: oldPath, to: newPath)
            }
        }
    }

    private func followRelocation(from oldPath: String, to newPath: String) {
        guard !isClosed else { return }
        let current = (filePath as NSString).standardizingPath
        let remapped: String
        if current == oldPath {
            remapped = newPath
        } else if current.hasPrefix(oldPath + "/") {
            remapped = newPath + current.dropFirst(oldPath.count)
        } else {
            return
        }
        filePath = remapped
        if noteBodyPath != nil {
            // Persisted bodyPath stays in its index-relative form (relative to
            // `<projectRoot>/.cmux`) so session restore resolves it against the
            // restored project root instead of pinning this machine's absolute
            // path.
            if let range = remapped.range(of: "/.cmux/", options: .backwards) {
                noteBodyPath = String(remapped[range.upperBound...])
            } else {
                noteBodyPath = remapped
            }
        }
        displayTitle = (remapped as NSString).lastPathComponent
        // Re-read from the new location (keeping any unsaved editor buffer)
        // and re-arm the watcher there; future saves also land at the new path.
        loadFileContent(replacingDirtyContent: false)
        startWatching()
    }

    /// Follow Notes-tree renames of index-owned notes (a record retitle; the
    /// body file does not move) so a panel open on the note shows the new
    /// title in its tab instead of the stale open-time one.
    private func observeNoteRetitles() {
        retitleObserver = NotificationCenter.default.addObserver(
            forName: .cmuxNoteRetitled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let bodyPath = notification.userInfo?["bodyPath"] as? String,
                  let title = notification.userInfo?["title"] as? String else { return }
            Task { @MainActor in
                self?.followRetitle(bodyPath: bodyPath, title: title)
            }
        }
    }

    private func followRetitle(bodyPath: String, title: String) {
        guard !isClosed, noteSlug != nil,
              (filePath as NSString).standardizingPath == bodyPath else { return }
        noteTitle = title
        displayTitle = title
    }

    /// Rename this note from its editor header (the Google-Docs-style title
    /// field). Routes through `CmuxNoteStore.retitle` — the same record
    /// mutation the Notes tree uses — then posts `.cmuxNoteRetitled` so this
    /// panel, any sibling panels on the same note, and the tree (via its
    /// `.cmux/notes` watcher on `index.json`) all adopt the new title.
    func renameNoteTitle(_ rawTitle: String) {
        guard !isClosed, let slug = noteSlug else { return }
        let bodyPath = (filePath as NSString).standardizingPath
        guard let projectRoot = NoteSupport.projectRoot(forNotePath: bodyPath) else { return }
        Task.detached(priority: .userInitiated) {
            guard let record = try? CmuxNoteStore.retitle(
                slug: slug, projectRoot: projectRoot, title: rawTitle
            ) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .cmuxNoteRetitled,
                    object: nil,
                    userInfo: ["bodyPath": bodyPath, "title": record.title]
                )
            }
        }
    }

    /// True for paths inside a TRUSTED `.cmux/notes` tree (the per-workspace
    /// Notes filesystem). Note classification turns on implicit writes
    /// (debounced autosave and the close flush), so a bare substring match is
    /// not enough: the project-controlled root components must not be
    /// symlinks, the file itself must not be one, and the canonical path must
    /// stay inside the notes root — otherwise a committed link like
    /// `.cmux/notes/x.md -> ~/.zshrc` would get silently autosaved through.
    static func isWorkspaceNotesPath(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard let projectRoot = NoteSupport.projectRoot(forNotePath: standardized) else { return false }
        guard NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) else { return false }
        let fm = FileManager.default
        if ((try? fm.attributesOfItem(atPath: standardized))?[.type] as? FileAttributeType)
            == .typeSymbolicLink {
            return false
        }
        let notesRoot = ((NoteSupport.notesDirectory(forProjectRoot: projectRoot) as NSString)
            .standardizingPath as NSString).resolvingSymlinksInPath
        let canonical = (standardized as NSString).resolvingSymlinksInPath
        guard canonical.hasPrefix(notesRoot + "/") else { return false }
        // Same body restrictions as CmuxNoteStore.absoluteBodyPath: note
        // behavior may only ever attach to visible `.md` bodies — never the
        // notes root itself, cmux metadata (`index.json`, tree markers), or
        // hidden components — otherwise opening `.cmux/notes/index.json` in a
        // markdown panel would autosave over the note index.
        let relative = canonical.dropFirst(notesRoot.count + 1)
            .split(separator: "/").map(String.init)
        return !relative.isEmpty
            && relative.allSatisfy { !CmuxNoteStore.isDisallowedBodyComponent($0) }
            && relative[relative.count - 1].lowercased().hasSuffix(".md")
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

    func setDisplayMode(_ mode: MarkdownPanelDisplayMode, focusTextEditor: Bool = true) {
        guard displayMode != mode else {
            if mode == .text, focusTextEditor {
                focus()
            }
            return
        }
        displayMode = mode
        if mode == .text, focusTextEditor {
            focus()
        } else if mode != .text {
            pendingTextViewFocus = false
        }
    }

    func markAsProjectNote(
        slug: String,
        id: String? = nil,
        bodyPath: String? = nil,
        title: String? = nil
    ) {
        noteSlug = slug
        noteID = id
        noteBodyPath = bodyPath
        noteTitle = title
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedTitle, !resolvedTitle.isEmpty {
            displayTitle = resolvedTitle
        } else {
            displayTitle = slug
        }
    }

    func attachTextView(_ textView: NSTextView) {
        self.textView = textView
        if pendingShowFindInterface {
            pendingShowFindInterface = false
            openFindBar(on: textView)
        }
    }

    /// Opens the system find bar over the note's source text (switching to
    /// text mode first — find operates on the source). If the editor is not
    /// attached yet (mode just switched), the open is deferred to attach,
    /// mirroring `pendingSearchNeedle`.
    func showFindInterface() {
        if displayMode != .text {
            setDisplayMode(.text)
        }
        if let textView, textView.window != nil {
            openFindBar(on: textView)
        } else {
            pendingShowFindInterface = true
        }
    }

    private func openFindBar(on textView: NSTextView) {
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(action)
    }

    func retryPendingFocus() {
        guard pendingTextViewFocus else { return }
        focus()
    }

    func applySearchNeedle(_ needle: String) {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSearchNeedle = trimmed
        setDisplayMode(.text)
        applyPendingSearchNeedleIfPossible()
    }

    /// True when this panel is a project note (opened through the note path).
    /// Notes auto-save; plain Markdown files keep the explicit Save control.
    var isProjectNote: Bool { noteSlug != nil }

    /// True when the file lives in a `.cmux/notes` tree — the per-workspace
    /// Notes filesystem. Classified by path so every entrypoint (Notes tab,
    /// session restore, file explorer) gives the same note behavior. Lazy:
    /// `filePath` is immutable and this is consulted on every keystroke via
    /// the autosave scheduler.
    private(set) lazy var isWorkspaceNotesFile: Bool = Self.isWorkspaceNotesPath(filePath)

    /// Note-behavior gate (auto-save, flush-on-close, no manual Save control):
    /// flat slug-indexed project notes plus Notes-tree files.
    var behavesAsNote: Bool { isProjectNote || isWorkspaceNotesFile }

    func updateTextContent(_ nextContent: String) {
        guard textContent != nextContent else { return }
        textContent = nextContent
        content = nextContent
        isDirty = nextContent != originalTextContent
        GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
        scheduleAutoSaveIfNeeded()
    }

    /// Debounce clock for note autosave; sleeping on it cancels with the task.
    private let autoSaveClock = ContinuousClock()

    /// Debounced auto-save for notes: write to disk shortly after the last
    /// keystroke so a note never needs a manual Save. No-op for plain Markdown.
    private func scheduleAutoSaveIfNeeded() {
        guard behavesAsNote, isDirty else { return }
        autoSaveTask?.cancel()
        let clock = autoSaveClock
        autoSaveTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.isDirty, !self.isClosed else { return }
            self.saveTextContent()
        }
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
        let savePath = (filePath as NSString).standardizingPath
        let fileURL = URL(fileURLWithPath: savePath)
        let encoding = textEncoding

        let requiresTrustedNoteWrite = behavesAsNote
        let task = Task {
            [weak self, currentContent, fileURL, encoding, generation, savePath, requiresTrustedNoteWrite] in
            let result: FilePreviewTextSaver.Result
            if requiresTrustedNoteWrite {
                result = await FilePreviewTextSaver.saveTrustedWorkspaceNote(
                    content: currentContent, to: fileURL, encoding: encoding
                )
            } else {
                result = await FilePreviewTextSaver.save(content: currentContent, to: fileURL, encoding: encoding)
            }
            guard let self, self.activeSaveGeneration == generation else { return }
            guard (self.filePath as NSString).standardizingPath == savePath else {
                self.activeSaveGeneration = nil
                self.isSaving = false
                self.isDirty = true
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
                if self.isClosed {
                    _ = self.saveTextContent()
                } else {
                    self.scheduleAutoSaveIfNeeded()
                }
                return
            }
            self.activeSaveGeneration = nil
            self.isSaving = false
            switch result {
            case .saved:
                self.originalTextContent = currentContent
                self.isDirty = self.textContent != currentContent
                self.isFileUnavailable = false
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
                // Edits made while this save was in flight leave isDirty == true.
                // If the panel is closing, the debounced autosave won't run, so flush
                // the latest text now — this write is ordered after the one that just
                // finished, so the newest content wins. Otherwise reschedule so autosave
                // continues without waiting for a new keystroke.
                if self.isDirty {
                    if self.isClosed {
                        _ = self.saveTextContent()
                    } else {
                        self.scheduleAutoSaveIfNeeded()
                    }
                }
            case .failed(let fileExists):
                self.isFileUnavailable = !fileExists
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
            }
        }
        activeSaveTask = task
        return task
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
