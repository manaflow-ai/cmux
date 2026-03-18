import AppKit
import Foundation
import Combine

/// A segment of markdown content — either regular markdown or a rendered fenced code block.
enum MarkdownSegment: Identifiable {
    case markdown(id: String, content: String)
    case fencedCode(id: String, language: String, code: String, renderedImage: NSImage?)

    var id: String {
        switch self {
        case .markdown(let id, _): return id
        case .fencedCode(let id, _, _, _): return id
        }
    }
}

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

    /// Font scale factor (1.0 = default). Persisted in UserDefaults.
    @Published var fontScale: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(fontScale), forKey: Self.fontScaleDefaultsKey)
        }
    }

    /// Minimum and maximum font scale bounds.
    static let minFontScale: CGFloat = 0.5
    static let maxFontScale: CGFloat = 3.0
    static let fontScaleStep: CGFloat = 0.1
    private static let fontScaleDefaultsKey = "MarkdownPanelFontScale"

    /// Parsed segments of the content (markdown + mermaid blocks).
    @Published private(set) var segments: [MarkdownSegment] = []

    /// Tracks the appearance used for the last mermaid render pass.
    private var lastRenderedDark: Bool?

    /// Observer for system appearance changes.
    private var appearanceObserver: NSObjectProtocol?

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

        let saved = UserDefaults.standard.double(forKey: Self.fontScaleDefaultsKey)
        self.fontScale = saved > 0 ? CGFloat(saved) : 1.0

        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            // Session restore can create a panel before the file is recreated.
            // Retry briefly so atomic-rename recreations can reconnect.
            scheduleReattach(attempt: 1)
        }
        startAppearanceObserver()
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
        stopAppearanceObserver()
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Font Scale

    @discardableResult
    func zoomIn() -> Bool {
        let newScale = min(fontScale + Self.fontScaleStep, Self.maxFontScale)
        guard newScale != fontScale else { return false }
        fontScale = newScale
        return true
    }

    @discardableResult
    func zoomOut() -> Bool {
        let newScale = max(fontScale - Self.fontScaleStep, Self.minFontScale)
        guard newScale != fontScale else { return false }
        fontScale = newScale
        return true
    }

    @discardableResult
    func resetZoom() -> Bool {
        guard fontScale != 1.0 else { return false }
        fontScale = 1.0
        return true
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
        parseSegments()
    }

    // MARK: - Fenced code segment parsing

    /// Stable ID from segment index and content prefix.
    private static func segmentId(index: Int, content: String) -> String {
        let prefix = String(content.prefix(64))
        return "\(index):\(prefix.hashValue)"
    }

    /// Build a regex that matches fenced code blocks for all registered renderer tags.
    /// Pattern captures: group 1 = language tag, group 2 = code content.
    private static func buildFencedCodePattern() -> NSRegularExpression? {
        let tags = FencedCodeRendererRegistry.shared.supportedTags
        guard !tags.isEmpty else { return nil }
        let escaped = tags.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        let pattern = "```(\(alternation))\\s*\\n([\\s\\S]*?)```"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// Parse content into segments, splitting on fenced code blocks with registered renderers.
    private func parseSegments() {
        let text = content
        guard !text.isEmpty else {
            segments = []
            return
        }

        guard let pattern = Self.buildFencedCodePattern() else {
            // No renderers registered — plain markdown
            segments = [.markdown(id: Self.segmentId(index: 0, content: text), content: text)]
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = pattern.matches(in: text, range: fullRange)

        guard !matches.isEmpty else {
            segments = [.markdown(id: Self.segmentId(index: 0, content: text), content: text)]
            return
        }

        var result: [MarkdownSegment] = []
        var lastEnd = 0
        var segIndex = 0

        for match in matches {
            let matchRange = match.range
            // Add preceding markdown text
            if matchRange.location > lastEnd {
                let mdRange = NSRange(location: lastEnd, length: matchRange.location - lastEnd)
                let mdText = nsText.substring(with: mdRange)
                if !mdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(id: Self.segmentId(index: segIndex, content: mdText), content: mdText))
                    segIndex += 1
                }
            }
            // Extract language tag (capture group 1) and code (capture group 2)
            let langRange = match.range(at: 1)
            let language = nsText.substring(with: langRange).lowercased()
            let codeRange = match.range(at: 2)
            let code = nsText.substring(with: codeRange).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(.fencedCode(id: Self.segmentId(index: segIndex, content: code), language: language, code: code, renderedImage: nil))
            segIndex += 1
            lastEnd = matchRange.location + matchRange.length
        }

        // Add trailing markdown text
        if lastEnd < nsText.length {
            let mdText = nsText.substring(from: lastEnd)
            if !mdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(id: Self.segmentId(index: segIndex, content: mdText), content: mdText))
            }
        }

        // Preserve rendered images for segments whose content hasn't changed
        let oldSegments = segments
        for (i, seg) in result.enumerated() {
            if case .fencedCode(let id, let lang, let code, _) = seg,
               let old = oldSegments.first(where: { $0.id == id }),
               case .fencedCode(_, _, _, let oldImage) = old,
               oldImage != nil {
                result[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: oldImage)
            }
        }

        segments = result
        renderFencedCodeSegments()
    }

    /// Render fenced code segments asynchronously via their registered renderers.
    private func renderFencedCodeSegments() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lastRenderedDark = isDark

        let registry = FencedCodeRendererRegistry.shared

        // Build active keys per renderer for cancellation
        var activeKeysByRenderer: [String: Set<String>] = [:]
        for segment in segments {
            guard case .fencedCode(_, let language, let code, let existingImage) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            let key = renderer.renderCacheKey(code: code, isDark: isDark)
            activeKeysByRenderer[language, default: []].insert(key)
        }
        for (language, keys) in activeKeysByRenderer {
            registry.renderer(for: language)?.cancelRendersExcept(activeKeys: keys)
        }

        for (index, segment) in segments.enumerated() {
            guard case .fencedCode(let id, let language, let code, let existingImage) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            renderer.render(code: code, isDark: isDark) { [weak self] image in
                guard let self else { return }
                guard index < self.segments.count,
                      case .fencedCode(let currentId, _, _, _) = self.segments[index],
                      currentId == id else { return }
                self.segments[index] = .fencedCode(id: id, language: language, code: code, renderedImage: image)
            }
        }
    }

    // MARK: - Appearance change observation

    private func startAppearanceObserver() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppearanceChangeIfNeeded()
        }
        // Also observe the effective appearance key path
        // NSApp posts this when system appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    private func stopAppearanceObserver() {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
            appearanceObserver = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private nonisolated func systemAppearanceDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppearanceChangeIfNeeded()
        }
    }

    private func handleAppearanceChangeIfNeeded() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard isDark != lastRenderedDark else { return }
        // Clear rendered images so they re-render with the new theme
        for (i, segment) in segments.enumerated() {
            if case .fencedCode(let id, let lang, let code, let image) = segment, image != nil {
                segments[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: nil)
            }
        }
        renderFencedCodeSegments()
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
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
