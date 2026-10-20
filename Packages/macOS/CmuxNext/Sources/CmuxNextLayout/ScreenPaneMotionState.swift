import CoreGraphics
import CmuxNextDesign

struct ScreenPaneMotionState {
    let provider: () -> PaneMotionVariant
    var frameSpring: MotionSpring = .move

    init(provider: @escaping () -> PaneMotionVariant) { self.provider = provider }
    var current: PaneMotionVariant { provider() }

    mutating func retarget(structural: Bool, inFlight: Bool, departing: Bool, zooming: Bool, hasFrames: Bool) {
        if structural && !inFlight {
            frameSpring = departing && !zooming ? current.closeSpring : .move
        } else if !hasFrames {
            frameSpring = .move
        }
    }
}
