import CoreGraphics
import CmuxNextDesign

struct ScreenPaneMotionState {
    let provider: () -> PaneMotionVariant
    var frameSpring: MotionSpring = .move

    init(provider: @escaping () -> PaneMotionVariant) { self.provider = provider }
    var current: PaneMotionVariant { provider() }

    /// The spring the pane and divider frames take for a change. A split (`splitting`, a pane
    /// growing in) takes `split`, a close the variant's close spring, anything else `move`; a
    /// change landing while a split still moves (`inFlight`, the daemon's echo) keeps the spring.
    mutating func retarget(structural: Bool, inFlight: Bool, departing: Bool, zooming: Bool, splitting: Bool = false, hasFrames: Bool) {
        if structural && !inFlight {
            frameSpring = departing && !zooming ? current.closeSpring : splitting ? current.splitSpring : .move
        } else if !hasFrames {
            frameSpring = .move
        }
    }
}
