import MessagesLabHome

/// The laid-out rows of one Home transcript, which a hidden conversation tab gives back
/// (`memoryDiscardConversations`, plans/cmux-next/chrome-parity/p07-memory.md 3.C, task 030): the rows, their
/// cells, the open thread view's rows and the bitmaps, tiles and decoded media only they drew. The view, its store
/// binding, the messages, the draft, the read state and the scroll place stay; after ``restore()`` the view's next
/// layout in its window lays out about 40 rows around that place.
@MainActor
public struct HomeTranscriptLayout {
    private let view: HomeNativeTranscriptView

    /// The layout of `view`'s transcript.
    public init(_ view: HomeNativeTranscriptView) {
        self.view = view
    }

    private var transcript: MessagesLabHomeView { view.transcript }

    /// Lets the laid-out rows go. False, and nothing goes, while rows still move (a send flying, a row fading)
    /// or before the first page installed the transcript.
    @discardableResult
    public func release() -> Bool { transcript.releaseLayout() }

    /// The tab shows again: the view's next layout in its window lays the rows out around the place they had, at
    /// the size the pane gives it then. Nothing when they are laid out.
    public func restore() { transcript.restoreLayout() }

    /// The rows were released and not laid out again yet (until the shown view's first layout in its window).
    public var isReleased: Bool { transcript.isLayoutReleased }

    /// Nothing moves in the transcript, so its rows can go.
    public var isAtRest: Bool { transcript.isLayoutAtRest }

    /// Laid-out rows, row cells (shown or pooled) and open thread view rows the transcript holds (0 once released).
    public var rowCacheCount: Int { transcript.layoutRowCount }
}
