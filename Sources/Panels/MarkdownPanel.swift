import AppKit
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

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
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
        GlobalSearchCoordinator.shared.purgePanel(id: id)
        textView = nil
        stopWatching()
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
        // DispatchSource cancel is safe from any thread.
        fileWatchSource?.cancel()
        directoryWatchSource?.cancel()
    }
}
