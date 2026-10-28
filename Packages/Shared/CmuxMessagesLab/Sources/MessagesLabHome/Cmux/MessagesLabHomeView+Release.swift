import AppKit

/// A hidden conversation gives back its laid-out transcript: the rows, their cells, the open thread
/// view's rows and the bitmaps, tiles and decoded media only they drew. The store keeps the messages, the draft, the
/// read state and every change that arrives meanwhile; the show lays out about 40 rows around the row that was at
/// the top (MessagesWindowView.releaseRows).
extension MessagesLabHomeView {
    /// Lets the laid-out rows go. False, and nothing goes, while rows still move (a send flying, a row fading) or
    /// before the first page installed the transcript.
    @discardableResult
    public func releaseLayout() -> Bool { controller.demo?.releaseRows() ?? false }

    /// The view shows again: its next layout in a window lays the rows out around the place they had, once, at the
    /// size and scale it has then (a hidden tab's view comes back to its pane after the show's lifecycle turn).
    /// Nothing when they are laid out.
    public func restoreLayout() {
        guard let demo = controller.demo, demo.rowsReleased else { return }
        demo.restoreRows()
        controller.host.needsLayout = true
    }

    /// The rows were released and not laid out again yet (a show asked for them and the view had no layout in a
    /// window since).
    public var isLayoutReleased: Bool { controller.demo?.rowsReleased ?? false }

    /// Nothing moves in the transcript, so its rows can go.
    public var isLayoutAtRest: Bool { controller.demo?.rowsAtRest ?? false }

    /// Laid-out rows, row cells (shown or pooled) and open thread view rows held (0 once released).
    public var layoutRowCount: Int { controller.demo?.rowCacheCount ?? 0 }
}
