public import AppKit

/// A pane's content that waits drawn, off screen in its window, while another tab shows (``AgentPageDrawnParking``),
/// so the switch back shows its last frame at once instead of a Chromium page told it is hidden dropping its frame
/// and drawing again (0.5 to 1.25 s, from the comments of `PageWebView+DrawnAway`). A chat conforms
/// (`AgentPaneView`), and an internal page (Settings, Markdown, a file viewer: `InternalPageView`). A browser
/// pane's page is a CEF `BrowserTab`, not a `PageWebView`; it joins by conforming here.
@MainActor
public protocol DrawnParkable: NSView {
    /// Whether it is one to keep drawn now: its page is in Chromium and has drawn, and nothing else (a crash notice,
    /// a running dictation) needs it hidden. The keeper adds: in a window, not hidden, not in Low Power Mode.
    var keepsDrawnNow: Bool { get }
    /// It was parked: the page is away to its document and owner (``PageWebView/setDrawnAway(_:)``).
    func parkedAway()
    /// A pane takes it back: the page is no longer away.
    func parkedBack()
    /// Right after ``parkedBack()``, before the pane places it.
    func placeAfterDrawnPark()
    /// The pane put it in its content and unhid it: its page's window follows.
    func shownAfterDrawnPark()
    /// A picture of its last frame, for the switch back once the keeper let it go hidden; nil when none can stand in.
    func drawnPicture() async -> NSImage?
    /// The picture stands under it until it draws again; the page is clear over it.
    func standOverDrawnPicture()
    /// The picture left.
    func drawnPictureWent()
    /// Runs `run` once the page drew its next frame.
    func afterDrawnFrame(_ run: @escaping @MainActor () -> Void)
}
