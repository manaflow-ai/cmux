/// Lifecycle of one cloud terminal's byte attachment.
enum CloudTuiManualMirrorPhase: Equatable, Sendable {
    case idle
    case connecting
    case attached
    case disconnected
    case stopped
}
