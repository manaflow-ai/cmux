import AppKit

/// A hidden conversation gives back its laid-out transcript (p07-memory-030): the rows, their cells and the
/// bitmaps they hold. The store keeps the messages, the draft, the read state and every change that arrives
/// meanwhile; the show lays out about 40 rows around the row that was at the top (MessagesWindowView.releaseRows).
extension MessagesLabHomeView {
    /// Lets the laid-out rows go. False, and nothing goes, while rows still move (a send flying, a row fading) or
    /// before the first page installed the transcript.
    @discardableResult
    public func releaseLayout() -> Bool { controller.demo?.releaseRows() ?? false }

    /// Lays the rows out again around the place they had, at the current width. Nothing when they are laid out.
    public func restoreLayout() { controller.demo?.restoreRows() }

    /// The rows were released and not laid out again yet.
    public var isLayoutReleased: Bool { controller.demo?.rowsReleased ?? false }

    /// Nothing moves in the transcript, so its rows can go.
    public var isLayoutAtRest: Bool { controller.demo?.rowsAtRest ?? false }

    /// Laid-out rows plus row cells held, shown or pooled (0 once released).
    public var layoutRowCount: Int { controller.demo?.rowCacheCount ?? 0 }
}
