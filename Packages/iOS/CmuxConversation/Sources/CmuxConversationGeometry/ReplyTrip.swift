import CoreGraphics
import Foundation

/// One thread row's trip into the reply thread or back, stepped once per
/// display frame: Messages' inline-reply layout dynamics, fitted to an
/// iPhone 17 Pro Max recording at 60 fps.
///
/// Each frame the row covers a fixed share of its remaining distance
/// (`easing`, see `ConversationReplyMotion.threadEasing`), and lands when
/// it is within `snapDistance`. A swiped bubble also swings sideways from
/// its release offset along `ConversationReplyMotion.offsetCurve`, reading
/// the trip as it stood before the frame's step (Messages' swing trails the
/// vertical travel by exactly one frame); a trip of under 2 pt walks the
/// offset back 6 pt per frame instead.
public struct ReplyTrip: Equatable, Sendable {
    /// Messages' first frame of a trip carries 1.15 frames of motion
    /// (measured 1.20, 1.19 going in and 1.13, 1.10 coming back).
    public static let firstStepFrames: CGFloat = 1.15

    public private(set) var startY: CGFloat
    public private(set) var targetY: CGFloat
    public private(set) var y: CGFloat
    public private(set) var offsetX: CGFloat
    public let initialOffsetX: CGFloat
    public let easing: CGFloat
    public let snapDistance: CGFloat
    public private(set) var stepCount = 0

    public init(startY: CGFloat, targetY: CGFloat, initialOffsetX: CGFloat, easing: CGFloat, snapDistance: CGFloat) {
        self.startY = startY
        self.targetY = targetY
        self.y = startY
        self.offsetX = initialOffsetX
        self.initialOffsetX = initialOffsetX
        self.easing = easing
        self.snapDistance = snapDistance
    }

    public var isResting: Bool { y == targetY && offsetX == 0 }

    /// The row's container moved by `delta`: it keeps its place on screen,
    /// so its start and current position move the other way.
    public mutating func containerMoved(by delta: CGFloat) {
        startY -= delta
        y -= delta
    }

    /// Advances one display frame of `frameDuration` seconds.
    public mutating func step(frameDuration: TimeInterval) {
        let frames = CGFloat(max(frameDuration, 0) * 60) * (stepCount == 0 ? Self.firstStepFrames : 1)
        stepCount += 1
        if initialOffsetX > 0 {
            let travel = max(abs(targetY - startY), 1)
            if y == targetY {
                offsetX = 0
            } else if travel < 2 {
                offsetX = max(0, offsetX - 6 * frames)
            } else {
                offsetX = max(0, initialOffsetX * ConversationReplyMotion.offsetCurve(progress: abs(y - startY) / travel))
            }
        }
        let k = ConversationReplyMotion.step(easing: easing, frameDuration: TimeInterval(frames) / 60)
        y += (targetY - y) * k
        if abs(targetY - y) < snapDistance { y = targetY }
    }
}
