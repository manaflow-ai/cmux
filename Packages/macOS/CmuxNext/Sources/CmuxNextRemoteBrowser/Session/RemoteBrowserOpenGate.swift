import Foundation

#if DEBUG
/// When a remote tab sends `rb.open` and `rb.screen`.
public nonisolated struct RemoteBrowserOpenGate: Sendable {
    public enum Step: Sendable, Equatable {
        case open(RbScreen)
        case resize(RbScreen)
    }

    private var screen: RbScreen?
    private var opened = false

    public init() {}

    public mutating func streaming() -> Step? {
        guard !opened else { return nil }
        opened = true
        let first = screen ?? RbScreen(viewport: RemoteBrowserViewport(bounds: .zero, backingScale: 1))
        screen = first
        return .open(first)
    }

    public mutating func viewport(_ viewport: RemoteBrowserViewport) -> Step? {
        let next = RbScreen(viewport: viewport)
        guard next != screen else { return nil }
        screen = next
        return opened ? .resize(next) : nil
    }
}
#endif
