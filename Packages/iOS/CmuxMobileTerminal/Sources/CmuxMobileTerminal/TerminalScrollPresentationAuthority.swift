/// Chooses which side may mutate the terminal mirror for a scroll gesture.
public enum TerminalScrollPresentationAuthority: Equatable, Sendable {
    /// Compatibility transports keep the historical low-latency local mirror.
    case legacyMirror
    /// Verified render-grid transport waits for the Mac's ordered frame.
    case verifiedRenderGrid

    public var appliesLocally: Bool {
        self == .legacyMirror
    }
}
