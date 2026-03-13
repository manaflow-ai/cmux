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

    /// Current markdown content read from the file (frontmatter stripped).
    @Published private(set) var content: String = ""

    /// Parsed YAML frontmatter key-value pairs, if present.
    @Published private(set) var frontmatter: [String: String] = [:]

    /// Title shown in the tab bar (frontmatter title or filename).
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
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.markdown-file-watch", qos: .utility)

    /// Maximum number of reattach attempts after a file delete/rename event.
    private static let maxReattachAttempts = 6
    /// Delay between reattach attempts (total window: attempts * delay = 3s).
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
            // Session restore can create a panel before the file is recreated.
            // Retry briefly so atomic-rename recreations can reconnect.
            scheduleReattach(attempt: 1)
        }
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
        stopFileWatcher()
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        let rawContent: String
        do {
            rawContent = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            // Fallback: try ISO Latin-1, which accepts all 256 byte values,
            // covering legacy encodings like Windows-1252.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                let (meta, body) = Self.stripFrontmatter(decoded)
                frontmatter = meta
                content = body
                updateTitleFromFrontmatter()
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
            return
        }

        let (meta, body) = Self.stripFrontmatter(rawContent)
        frontmatter = meta
        content = body
        updateTitleFromFrontmatter()
        isFileUnavailable = false
    }

    /// Update the display title from frontmatter `title` key, falling back
    /// to the filename.
    private func updateTitleFromFrontmatter() {
        if let title = frontmatter["title"], !title.isEmpty {
            displayTitle = title
        } else {
            displayTitle = (filePath as NSString).lastPathComponent
        }
    }

    // MARK: - Frontmatter parsing

    /// Strips a leading YAML frontmatter block (`---` … `---`) from the
    /// given string. Returns the parsed key-value pairs and the remaining
    /// markdown body. Only simple `key: value` pairs are supported;
    /// nested YAML structures are ignored to avoid a heavyweight dependency.
    static func stripFrontmatter(_ text: String) -> (metadata: [String: String], body: String) {
        // Frontmatter must start at the very beginning of the file.
        guard text.hasPrefix("---") else { return ([:], text) }

        // Find the closing `---` delimiter. We skip the opening line and
        // search for a line that is exactly `---` (with optional trailing
        // whitespace).
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return ([:], text) }

        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let endIndex = closingIndex else { return ([:], text) }

        // Parse simple `key: value` pairs from the frontmatter block.
        var metadata: [String: String] = [:]
        for i in 1..<endIndex {
            let line = lines[i]
            guard let colonRange = line.range(of: ":") else { continue }
            let key = line[line.startIndex..<colonRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            var value = line[colonRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes if present.
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                metadata[key] = value
            }
        }

        // The body starts after the closing `---` line.
        let bodyLines = Array(lines[(endIndex + 1)...])
        // Trim a single leading blank line that often follows the closing delimiter.
        let body: String
        if let first = bodyLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            body = bodyLines.dropFirst().joined(separator: "\n")
        } else {
            body = bodyLines.joined(separator: "\n")
        }

        return (metadata, body)
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
                // File was deleted or renamed. The old file descriptor points to
                // a stale inode, so we must always stop and reattach the watcher
                // even if the new file is already readable (atomic save case).
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    self.loadFileContent()
                    if self.isFileUnavailable {
                        // File not yet replaced — retry until it reappears.
                        self.scheduleReattach(attempt: 1)
                    } else {
                        // File already replaced — reattach to the new inode immediately.
                        self.startFileWatcher()
                    }
                }
            } else {
                // Content changed — reload.
                DispatchQueue.main.async {
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

    /// Retry reattaching the file watcher up to `maxReattachAttempts` times.
    /// Each attempt checks if the file has reappeared. Bails out early if
    /// the panel has been closed.
    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.isFileUnavailable = false
                    self.loadFileContent()
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        // File descriptor is closed by the cancel handler.
        fileDescriptor = -1
    }

    deinit {
        // DispatchSource cancel is safe from any thread.
        fileWatchSource?.cancel()
    }
}
