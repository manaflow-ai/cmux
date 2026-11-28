import Foundation

#if DEBUG
/// When a remote tab sends `rb.open` and `rb.screen`: `rb.open` carries the
/// pane's real size, so it waits for both the rd session streaming and the
/// page view's first non-empty layout, whichever comes last (an event, not a
/// timer). Before that the host would lay the page out at a 1x1 screen.
/// After the open, every real size change is one `rb.screen`; an empty
/// layout (a collapsed pane) is never sent.
public nonisolated struct RemoteBrowserOpenGate: Sendable {
    public enum Step: Sendable, Equatable {
        case open(RbScreen)
        case resize(RbScreen)
    }

    private var screen: RbScreen?
    private var isStreaming = false
    private var opened = false

    public init() {}

    /// The rd session streams.
    public mutating func streaming() -> Step? {
        guard !isStreaming else { return nil }
        isStreaming = true
        return openIfReady()
    }

    /// The page view's viewport may have changed.
    public mutating func viewport(_ viewport: RemoteBrowserViewport) -> Step? {
        guard !viewport.isEmpty else { return nil }
        let next = RbScreen(viewport: viewport)
        guard next != screen else { return nil }
        screen = next
        return opened ? .resize(next) : openIfReady()
    }

    private mutating func openIfReady() -> Step? {
        guard isStreaming, !opened, let screen else { return nil }
        opened = true
        return .open(screen)
    }
}
#endif
