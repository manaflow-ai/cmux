/// Saturation may recover on rebind; pane/connection invalidation is terminal.
enum CloudTuiManualIOAdmissionPhase: Equatable, Sendable {
    case open
    case saturated
    case invalidated
}
