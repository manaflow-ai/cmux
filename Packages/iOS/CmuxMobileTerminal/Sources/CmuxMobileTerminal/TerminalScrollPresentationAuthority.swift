/// Chooses which side may mutate the terminal mirror for a scroll gesture.
public enum TerminalScrollPresentationAuthority: Equatable, Sendable {
    /// Compatibility transports keep the historical low-latency local mirror.
    case legacyMirror
    /// Screen-anchored primary terminals use a bounded UIKit pixel viewport.
    case localPixelViewport
    /// Verified render-grid transport waits for the Mac's ordered frame.
    case verifiedRenderGrid

    /// Whether gestures may mutate the phone's local Ghostty mirror.
    public var appliesLocally: Bool {
        self != .verifiedRenderGrid
    }

    /// Whether gestures select exact rows plus a fractional renderer offset.
    public var usesBoundedPixelViewport: Bool {
        self == .localPixelViewport
    }
}
