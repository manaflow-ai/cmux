import Foundation

/// How fast Home animates (`ui.animationSpeed`, plans/cmux-next/motion.md rule 8).
public enum HomeAnimationSpeed: Sendable, Hashable {
    /// The fitted timing (the default).
    case fast
    /// Every time constant x1.5.
    case normal
    /// Every change lands in one frame: no springs, no cross-fade, no loops.
    case off

    var factor: Double {
        switch self {
        case .fast, .off: 1
        case .normal: 1.5
        }
    }
}

/// Every duration, curve and spring of the Home renderer.
///
/// plans/cmux-next/motion.md rule 1: one module owns the timing and every
/// animation asks it for a token. CmuxNextDesign's `Motion` is macOS-only, so
/// the shared render core keeps its own token table here; nothing else in
/// this module states a duration or a spring constant. The multi-component
/// elements are the fitted values (position and opacity measured frame by
/// frame on a reference recording, fitted as sums of springs); their
/// `from`/`to` are the fitted 2x-pixel endpoints and only their ratios matter
/// for a move. The single-spring tokens are effects the fit did not
/// constrain, expressed with the same physics.
enum HomeMotion {
    private static func element(_ name: String, from: Double, to: Double,
                                _ components: [(delay: Double, duration: Double, bounce: Double, delta: Double)]) -> SpringElement {
        SpringElement(name: name, from: from, to: to, components: components.map {
            SpringElement.Component(delay: $0.delay, spring: Spring(duration: $0.duration, bounce: $0.bounce), delta: $0.delta)
        })
    }

    private static func simple(_ name: String, delay: Double = 0, duration: Double, bounce: Double = 0) -> SpringElement {
        element(name, from: 0, to: 1, [(delay, duration, bounce, 1)])
    }

    // MARK: Fitted transcript moves (rows above a change shift by its height)

    static let send = element("transcript.send", from: 0, to: -122, [(0.0004, 0.2999, 0, -122)])
    static let delivered = element("transcript.delivered", from: 0.004, to: -31.997,
                                   [(0.0716, 0.307, 0.152, -27.386), (0.0013, 0.1746, 0.7695, -4.615)])
    static let read = element("transcript.read", from: 0, to: 34.996,
                              [(0.0385, 0.5487, 0.0993, 45.238), (0.2323, 0.3704, 0.0763, -10.242)])
    static let typing = element("transcript.typing", from: 0, to: -70,
                                [(-0.0064, 0.3826, 0.1193, -89.775), (-0.001, 0.2425, 0.6338, 19.775)])
    static let receive = element("transcript.receive", from: 0, to: -62,
                                 [(-0.0183, 0.3008, 0.0975, -76.994), (0.0008, 0.1944, 0.589, 14.994)])

    // MARK: Fitted send morph (the compose field becomes the bubble)

    static let bubbleRight = element("bubble.right", from: 1154, to: 1215, [(-0.0064, 0.5265, 0.3011, 61)])
    static let bubbleWidth = element("bubble.width", from: 1052, to: 300,
                                     [(-0.015, 0.4104, 0.1434, -440.0225), (0.0384, 0.2569, 0.4308, -311.9775)])
    static let bubbleCenterY = element("bubble.centerY", from: 1997, to: 1904, [(0.0553, 0.4784, 0.1927, -93)])
    /// A pulse: scale dips and returns (deltas are absolute scale).
    static let bubbleScale = element("bubble.scale", from: 1, to: 1,
                                     [(0.0748, 0.3882, 0.4956, -0.4512), (0.15, 0.2336, 0, 0.4512)])
    /// Starts at 0.59 opacity (`from` is used as the start value).
    static let bubbleOpacity = element("bubble.opacity", from: 0.59, to: 1, [(0.0927, 0.1624, 0.1185, 0.41)])
    static let fieldTop = element("field.top", from: 1933.1, to: 1999.1, [(0.0048, 0.3853, 0.1389, 66)])
    /// A pulse: the field glass dims and returns (deltas are absolute opacity).
    static let fieldOpacity = element("field.opacity", from: 1, to: 1,
                                      [(0.0422, 0.328, 0.4356, -2.616), (0.087, 0.2637, 0, 2.616)])

    // MARK: Single-spring effects

    // motion-allow: the render core's motion module (motion.md rule 1)
    static let typingPop = simple("typing.pop", delay: 0.05, duration: 0.209)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let typingFade = simple("typing.fade", delay: 0.05, duration: 0.12)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let typingOut = simple("typing.out", delay: 0.02, duration: 0.2)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let receivedFade = simple("received.fade", delay: 0.2, duration: 0.2)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let receiptIn = simple("receipt.in", delay: 0.085, duration: 0.15)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let receiptOldOut = simple("receipt.oldOut", delay: 0.06, duration: 0.14)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let receiptNewIn = simple("receipt.newIn", delay: 0.2, duration: 0.26)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let rowFade = simple("row.fade", duration: 0.2)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let textUnblur = simple("text.unblur", delay: 0.07, duration: 0.12)
    // motion-allow: the render core's motion module (motion.md rule 1)
    static let fieldGrow = simple("field.grow", duration: 0.1)

    // MARK: Timed effects and loops

    /// Reduce Motion: the old frame fades out over the new one (motion.md
    /// rule 7 caps the cross-fade at 0.1 s).
    static let crossFade: Double = 0.1
    /// A removed row stays as a zero-height ghost this long while it fades.
    static let ghostLifetime: Double = 1.0
    /// Typing dots: one brightness pulse per dot per period, `typingDotStagger` apart.
    static let typingDotPeriod: Double = 1
    static let typingDotStagger: Double = 0.26
    static let typingDotWidth: Double = 0.22
    /// Caret: solid for `caretHold` after an edit, then blinks once per period.
    static let caretHold: Double = 0.99
    static let caretPeriod: Double = 1
    /// The caret shows grey this long after a send.
    static let caretSendGray: Double = 0.65
    /// The morph lands when every element is this close to rest (points / opacity).
    static let landTolerance: Double = 0.1
    static let landOpacityTolerance: Double = 0.01
    /// Momentum: the system trackpad decay (x0.92 per 120 Hz frame).
    static let momentumDecayPerFrame: Double = 0.92
    static let momentumFrameRate: Double = 120
    /// Scroll gestures keep the cleanup quiet this long after the last event.
    static let scrollQuiet: Double = 0.12
}

/// The motion settings in force: Reduce Motion and `ui.animationSpeed`.
struct MotionPolicy: Hashable, Sendable {
    var reduceMotion = false
    var speed: HomeAnimationSpeed = .fast

    /// Movement animates (springs). False under Reduce Motion and `off`.
    var moves: Bool { !reduceMotion && speed != .off }
    /// Reduce Motion replaces movement with a short cross-fade (`off` wins: no fade).
    var crossFades: Bool { reduceMotion && speed != .off }
    /// Decorative loops (typing dots) run; Reduce Motion shows them static.
    var loops: Bool { speed != .off && !reduceMotion }
    /// The caret blinks (a text-editing affordance, kept under Reduce Motion).
    var caretBlinks: Bool { speed != .off }

    func callAsFunction(_ element: SpringElement) -> SpringElement { element.scaled(speed.factor) }
    func time(_ seconds: Double) -> Double { seconds * speed.factor }
}
