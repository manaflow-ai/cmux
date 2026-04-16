import AppKit
import Combine
import Foundation

/// A panel that provides a simple text editor for a file.
/// Tracks dirty state, supports save, and watches for external file changes.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Absolute path to the file being edited.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current text content of the editor.
    @Published var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.text" }

    /// Whether the file has unsaved changes.
    @Published private(set) var isDirty: Bool = false

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Weak reference to the AppKit text view so focus() can make it first responder.
    weak var textView: NSTextView?

    /// Optional hook set by a backend view (currently Monaco) that lets callers
    /// synchronously force the live buffer out of the underlying editor into
    /// `content` before a save or close decision runs. Returns `true` when
    /// the backend was reachable and any pending edits have been mirrored
    /// into `content`, `false` when the bridge wasn't available (webview
    /// still booting) and save must not proceed. Without this, a fast Cmd+W
    /// or Cmd+S right after a keystroke can race the Monaco debounced
    /// `changed` message and lose the newest edits.
    var backendFlush: (() async -> Bool)?

    /// Optional hook invoked after a successful `save()` so the backend can
    /// snapshot its "clean" baseline. Monaco uses this to reset its internal
    /// savedVersionId so the next edit emits a fresh dirty transition.
    var backendAfterSave: (() async -> Void)?

    /// Optional hook the backend view registers so `focus()` can restore
    /// first-responder for web-based backends (Monaco's WKWebView). Returns
    /// `true` when the backend was alive and actually delivered focus,
    /// `false` when its captured coordinator has gone away (backend swap,
    /// tab detach) — the caller then falls back to the native `textView`
    /// path instead of silently no-op-ing.
    var backendFocus: (() -> Bool)?

    /// Last known cursor/selection state. Persisted via session snapshot and
    /// restored into the text view when it is created.
    var cursorLocation: Int = 0
    var cursorLength: Int = 0

    /// Scroll offset as a 0..1 fraction of the scrollable range. Shared across
    /// both editor backends so toggling between native and Monaco preserves
    /// approximate viewport even when window size changed in between.
    var scrollTopFraction: Double = 0

    /// Opaque JSON-encoded Monaco `ICodeEditorViewState`. Preferred over the
    /// flat cursor/scroll fields when the Monaco backend restores the panel.
    var monacoViewState: String?

    /// Seconds since epoch the panel was last interacted with. Updated from
    /// view-state events and consumed by session persistence for MRU sorting.
    var lastOpenedAt: Double = Date().timeIntervalSince1970

    /// Encoding detected when the file was loaded. Preserved on save so legacy-encoded
    /// files are not silently re-encoded to UTF-8.
    private var originalEncoding: String.Encoding = .utf8

    /// The saved content, used to detect dirty state.
    private var savedContent: String = ""

    // MARK: - File watching

    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.editor-file-watch", qos: .utility)
    /// Suppresses file-watcher reloads immediately after a save.
    private var suppressNextReload: Bool = false

    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            scheduleReattach()
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Monaco registers a hook that routes through its WKWebView; when
        // set AND reachable, prefer it. If the closure reports back false
        // (its captured coordinator has been deallocated, e.g. after a
        // backend swap), fall through to the native NSTextView path so
        // the tab still gets keyboard focus.
        if let backendFocus, backendFocus() {
            return
        }
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func unfocus() {
        // NSTextView resigns naturally when another panel takes first responder.
    }

    func close() {
        // The dirty-buffer save/discard decision is made by the workspace's
        // `shouldCloseTab` confirmation path before `close()` is ever called;
        // this hook only tears down the file watcher.
        isClosed = true
        stopFileWatcher()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    /// Update the workspace this panel belongs to. Called when a tab is moved
    /// to a different workspace so any workspace-scoped state keeps routing to
    /// the correct container.
    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    // MARK: - Dirty tracking

    func markDirty() {
        let dirty = content != savedContent
        if isDirty != dirty {
            isDirty = dirty
            updateDisplayTitle()
        }
    }

    /// Synchronous dirty ping pushed from the Monaco backend on every
    /// keystroke (via the JS `dirty` bridge message) so close/save-on-close
    /// gating can see the correct state before the debounced full-buffer
    /// `changed` message catches up. Keep this cheap: just flip the flag
    /// and refresh the title.
    func setBackendDirty(_ value: Bool) {
        guard isDirty != value else { return }
        isDirty = value
        updateDisplayTitle()
    }

    // MARK: - Save

    /// Saves the current content to disk using the file's original encoding.
    /// Returns `true` on success. On failure, the dirty state is preserved.
    ///
    /// Atomic writes (`write(toFile:atomically:)`) create a sibling temp file
    /// and rename over the target. When the target is a symlink, that rename
    /// replaces the symlink with a regular file, silently breaking the link.
    /// We resolve symlinks up-front so the atomic write operates on the real
    /// destination path and the link object in the user's tree is preserved.
    @discardableResult
    func save() -> Bool {
        guard isDirty else { return true }
        let targetPath = resolvedSavePath()
        do {
            suppressNextReload = true
            try content.write(toFile: targetPath, atomically: true, encoding: originalEncoding)
            savedContent = content
            isDirty = false
            updateDisplayTitle()
            return true
        } catch {
            suppressNextReload = false
            #if DEBUG
            NSLog("editor.save failed path=%@ error=%@", filePath, "\(error)")
            #endif
            return false
        }
    }

    /// Resolve the save target so an atomic write won't clobber a symlink
    /// with a regular file. If the user opened `foo.txt` and it's a symlink
    /// to `real.txt`, we write to `real.txt` and the link survives. Falls
    /// back to the original path when the symlink can't be resolved.
    private func resolvedSavePath() -> String {
        let original = (filePath as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: original),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink else {
            return original
        }
        let resolved = URL(fileURLWithPath: original).resolvingSymlinksInPath().path
        return resolved.isEmpty ? original : resolved
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            originalEncoding = .utf8
            content = newContent
            savedContent = newContent
            isDirty = false
            isFileUnavailable = false
        } catch {
            // Fallback: ISO Latin-1 accepts all 256 byte values, covering legacy encodings.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                originalEncoding = .isoLatin1
                content = decoded
                savedContent = decoded
                isDirty = false
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
        updateDisplayTitle()
    }

    private func updateDisplayTitle() {
        let filename = (filePath as NSString).lastPathComponent
        displayTitle = isDirty ? "\(filename) *" : filename
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    guard !self.isClosed else { return }
                    // Always clear the suppression flag when an event fires so a
                    // missed event can't silently swallow future external edits.
                    let wasSuppressed = self.suppressNextReload
                    self.suppressNextReload = false
                    self.stopFileWatcher()
                    if wasSuppressed {
                        self.startFileWatcher()
                    } else if self.isDirty {
                        // Preserve the dirty buffer; just re-attach the watcher to the new inode.
                        if FileManager.default.fileExists(atPath: self.filePath) {
                            self.startFileWatcher()
                        } else {
                            self.scheduleReattach()
                        }
                    } else {
                        self.loadFileContent()
                        if self.isFileUnavailable {
                            self.scheduleReattach()
                        } else {
                            self.startFileWatcher()
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    guard !self.isClosed else { return }
                    let wasSuppressed = self.suppressNextReload
                    self.suppressNextReload = false
                    if !wasSuppressed && !self.isDirty {
                        self.loadFileContent()
                    }
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    /// Keep retrying until the file reappears AND we successfully install a watcher,
    /// or the panel is closed. Atomic saves by external editors may take longer than
    /// a fixed window, so there is no attempt cap.
    private func scheduleReattach() {
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                guard FileManager.default.fileExists(atPath: self.filePath) else {
                    self.scheduleReattach()
                    return
                }
                if !self.isDirty {
                    self.loadFileContent()
                }
                self.startFileWatcher()
                // Reattach is done once a watcher is installed. When the buffer
                // is dirty we intentionally skipped loadFileContent(), so
                // isFileUnavailable may still be stale from before — don't treat
                // that as a retry signal. Only keep retrying if the watcher
                // failed to install, or we tried to load and it genuinely failed.
                if self.fileWatchSource == nil || (!self.isDirty && self.isFileUnavailable) {
                    self.scheduleReattach()
                } else {
                    self.isFileUnavailable = false
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }

    deinit {
        fileWatchSource?.cancel()
    }
}
