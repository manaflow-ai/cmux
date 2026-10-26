import MessagesLabHome

/// The laid-out rows of one Home transcript, which a hidden conversation tab gives back
/// (`memoryDiscardConversations`, plans/cmux-next/chrome-parity/p07-memory.md 3.C, task 030): the rows, their
/// cells and the bitmaps they hold. The view, its store binding, the messages, the draft, the read state and the
/// scroll place stay; ``restore()`` lays out about 40 rows around that place.
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

    /// Lays the rows out again around the place they had, at the view's current width. Nothing when they are laid out.
    public func restore() { transcript.restoreLayout() }

    /// The rows were released and not laid out again yet.
    public var isReleased: Bool { transcript.isLayoutReleased }

    /// Nothing moves in the transcript, so its rows can go.
    public var isAtRest: Bool { transcript.isLayoutAtRest }

    /// Laid-out rows plus row cells the transcript holds, shown or pooled (0 once released).
    public var rowCacheCount: Int { transcript.layoutRowCount }
}
