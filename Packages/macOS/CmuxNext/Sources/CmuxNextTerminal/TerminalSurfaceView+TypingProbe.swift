public import CmuxNextWakeups

// The typing probe follows the terminal a key went to (``TypingLatencyProbe/Target``): its view identity scopes
// the lane, IO bridge and layer marks; its daemon surface, when the session's IO has one, the attach socket's.
extension TerminalSurfaceView: TypingProbeTargeting {
    /// This view's identity as the probe scopes its marks.
    nonisolated var typingProbeView: Int { ObjectIdentifier(self).hashValue }

    public var typingProbeTarget: TypingLatencyProbe.Target {
        TypingLatencyProbe.Target(surface: session?.io.probeSurface, view: typingProbeView)
    }
}
