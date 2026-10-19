/// Lifecycle of one cloud terminal's byte attachment.
public enum CloudTuiManualMirrorPhase: Equatable, Sendable {
    case idle
    case connecting
    case attached
    case disconnected
    case stopped
}
