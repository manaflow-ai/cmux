import AppKit

/// A line and column to select once a file preview shows its text.
struct FilePreviewRevealLocation: Equatable, Sendable {
    /// 1-based line.
    let line: Int
    /// 1-based column in UTF-16 code units.
    let column: Int
    /// Characters to select, in UTF-16 code units.
    let length: Int

    /// The range to select in `text`, clamped to the line's content.
    func range(in text: NSString) -> NSRange {
        var lineStart = 0
        var currentLine = 1
        while currentLine < line, lineStart < text.length {
            var end = 0
            text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: lineStart, length: 0))
            guard end > lineStart else { break }
            lineStart = end
            currentLine += 1
        }
        guard currentLine == line else {
            return NSRange(location: text.length, length: 0)
        }
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(lineStart, text.length), length: 0))
        let location = min(lineStart + max(column - 1, 0), contentsEnd)
        return NSRange(location: location, length: min(max(length, 0), contentsEnd - location))
    }
}

/// Hands a search result's location to the file preview that opens it.
///
/// Opening goes through the shared open path, which knows only the file path
/// and may finish later (a remote file downloads first). The requester files
/// the location here under the path it opened; the preview showing that path
/// selects it once its text is in place. Requests expire so a stale one
/// cannot move the selection when the same file opens later for another reason.
@MainActor
final class FilePreviewRevealCenter {
    static let shared = FilePreviewRevealCenter()
    static let requestLifetime: Duration = .seconds(15)

    private struct Request {
        let location: FilePreviewRevealLocation
        let requestedAt: ContinuousClock.Instant
    }

    private var requests: [String: Request] = [:]
    private let panels = NSHashTable<FilePreviewPanel>.weakObjects()
    private let clock = ContinuousClock()

    /// Files `location` for the preview of `path` and applies it at once if
    /// that preview is already showing its text.
    func request(_ location: FilePreviewRevealLocation, forPath path: String) {
        requests[path] = Request(location: location, requestedAt: clock.now)
        for panel in panels.allObjects where panel.revealPath == path {
            panel.applyPendingRevealIfPossible()
        }
    }

    /// Takes the pending location for `path`, if it is still current.
    func takeRequest(forPath path: String) -> FilePreviewRevealLocation? {
        guard let request = requests.removeValue(forKey: path) else { return nil }
        guard clock.now - request.requestedAt < Self.requestLifetime else { return nil }
        return request.location
    }

    func hasRequest(forPath path: String) -> Bool {
        requests[path] != nil
    }

    /// Previews register when they attach a text view.
    func track(_ panel: FilePreviewPanel) {
        panels.add(panel)
    }
}

extension FilePreviewPanel {
    /// The path search results use for this preview: the remote path for a
    /// downloaded remote file, otherwise the local path.
    var revealPath: String { cloudPreviewRemotePath ?? filePath }

    func textEditorDidApplyContent() {
        applyPendingRevealIfPossible()
    }

    /// Selects and scrolls to a pending search location once the text view
    /// shows this file's loaded text.
    func applyPendingRevealIfPossible() {
        let center = FilePreviewRevealCenter.shared
        center.track(self)
        let path = revealPath
        guard center.hasRequest(forPath: path),
              let textView,
              textContentRevision > 0 || !textContent.isEmpty,
              textView.string == textContent,
              let location = center.takeRequest(forPath: path) else { return }
        let range = location.range(in: textView.string as NSString)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.centerSelectionInVisibleArea(nil)
        if range.length > 0 {
            textView.showFindIndicator(for: range)
        }
    }
}
