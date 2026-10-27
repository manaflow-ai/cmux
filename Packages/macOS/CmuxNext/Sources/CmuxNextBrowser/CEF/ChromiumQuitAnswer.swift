/// How Chromium's pages answered a quit (``CEFEngine/askPagesBeforeQuit(showWindows:)``, task 087 of
/// plans/cmux-next/chrome-parity/p01-process.md).
public nonisolated enum ChromiumQuitAnswer: Equatable, Sendable {
    /// Every page lets the quit go on; `asked` when a page asked the person ("Leave site?") and they chose Leave.
    case leave(asked: Bool)
    /// The person chose Stay on a page: cmux keeps running and every page stays as it was.
    case stay
}
