import Foundation

/// Where a Markdown file's table column widths live between opens
/// (plans/cmux-next/MARKDOWN-TABLE-WIDTHS-DESIGN.md). The value is the page's own compact JSON
/// (`{"v":1,"tables":[{"i":0,"h":"…","w":[120,80]}]}`); the store keeps it as bytes and never reads
/// or writes the file's content.
nonisolated protocol MarkdownTableWidthStoring: Sendable {
    /// The saved widths of the file at `path` (canonical), or nil when none are saved.
    func read(_ path: String) async -> Data?
    /// Saves `value` for the file at `path`, or with nil forgets it.
    @discardableResult
    func write(_ path: String, _ value: Data?) async -> MarkdownTableWidthWrite
}

/// Where a ``MarkdownTableWidthStoring/write(_:_:)`` landed.
nonisolated struct MarkdownTableWidthWrite: Equatable, Sendable {
    /// The file's extended attribute took it.
    var attribute: Bool
    /// The app's own copy took it (the fallback for volumes and editors that drop attributes).
    var fallback: Bool
}
