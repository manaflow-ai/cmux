/// The Core Animation key each indicator animation runs under
/// (`StatusIndicatorLayer.runningAnimation` reads it back).
extension StatusIndicatorPlan.Animation {
    var key: String {
        switch self {
        case .spin: "spin"
        case .step: "step"
        case .pulse: "pulse"
        case .frames: "frames"
        case .wave: "wave"
        }
    }

    init?(key: String) {
        switch key {
        case "spin": self = .spin
        case "step": self = .step
        case "pulse": self = .pulse
        case "frames": self = .frames
        case "wave": self = .wave
        default: return nil
        }
    }
}
