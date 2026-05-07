import Foundation
import Combine

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

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
    private var watcherRetryWorkItem: DispatchWorkItem?
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
        // Markdown panel is read-only; no first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        isClosed = true
        stopWatching()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            content = newContent
            isFileUnavailable = false
        } catch {
            // Fallback: try ISO Latin-1, which accepts all 256 byte values,
            // covering legacy encodings like Windows-1252.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                content = decoded
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
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
        cancelWatcherRetry()

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
                    self.loadFileContent()
                    // Reattach to the replacement inode when atomic-save
                    // already created it; otherwise watch the directory until
                    // the file comes back.
                    self.startFileWatcher()
                }
            } else {
                // Content changed — reload.
                DispatchQueue.main.async {
                    guard !self.isClosed else { return }
                    self.loadFileContent()
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
            cancelWatcherRetry()

            installDirectoryWatcher(fileDescriptor: fd, directoryPath: directoryPath)
            return
        }

        scheduleWatcherRetry()
    }

    private func installDirectoryWatcher(fileDescriptor fd: Int32, directoryPath: String) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                self.loadFileContent()
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

    private func scheduleWatcherRetry() {
        guard watcherRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watcherRetryWorkItem = nil
            guard !self.isClosed else { return }
            self.startFileWatcher()
        }
        watcherRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func cancelWatcherRetry() {
        watcherRetryWorkItem?.cancel()
        watcherRetryWorkItem = nil
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
        cancelWatcherRetry()
    }

    deinit {
        // DispatchSource cancel is safe from any thread.
        fileWatchSource?.cancel()
        directoryWatchSource?.cancel()
        watcherRetryWorkItem?.cancel()
    }
}
