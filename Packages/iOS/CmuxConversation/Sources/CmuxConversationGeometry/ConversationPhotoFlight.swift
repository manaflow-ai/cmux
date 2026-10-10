import CoreGraphics
import Foundation

/// Geometry of the photo zoom between a bubble and the full-screen viewer.
public enum ConversationPhotoFlight {
    /// Spring response, measured from Messages' viewer close (the flight
    /// settles in about 0.43 s on iOS 26.5).
    public static let response: Double = 0.42
    /// When the critically damped spring is within half a point per 400 pt.
    public static var settleTime: Double { response * 1.35 }

    /// A critically damped spring from 0 to 1 (`response` is its period).
    public static func progress(at t: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        guard t < settleTime else { return 1 }
        let omega = 2 * Double.pi / response
        let value = 1 - (1 + omega * t) * exp(-omega * t)
        // Land exactly at 1 at the settle time instead of a sub-pixel jump.
        let end = 1 - (1 + omega * settleTime) * exp(-omega * settleTime)
        return CGFloat(min(1, value / end))
    }

    public static func interpolate(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * p,
            y: a.minY + (b.minY - a.minY) * p,
            width: a.width + (b.width - a.width) * p,
            height: a.height + (b.height - a.height) * p
        )
    }

    /// The flying photo's outline in `rect` (its full frame, tail area
    /// included): a Messages bubble with corner `radius`. When `tailed`, the
    /// tail drops below the body by `iOSTailDrop(radius:)`, so the corners
    /// and the tail grow and shrink together and reach a plain rectangle at
    /// radius 0 (the full-screen photo).
    public static func outline(in rect: CGRect, radius: CGFloat, side: ConversationBubbleGeometry.Side, tailed: Bool) -> CGPath {
        guard radius > 0.01 else { return CGPath(rect: rect, transform: nil) }
        var body = rect
        if tailed { body.size.height = max(0, rect.height - ConversationBubbleGeometry.iOSTailDrop(radius: radius)) }
        return ConversationBubbleGeometry.iOSPath(in: body, side: side, tail: tailed, radius: radius)
    }
}
