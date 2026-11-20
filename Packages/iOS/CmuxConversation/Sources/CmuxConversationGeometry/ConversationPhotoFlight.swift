import CoreGraphics
import Foundation

/// Geometry of the photo zoom between a bubble and the full-screen viewer
/// on iOS 26, where Messages hands photos to Quick Look.
///
/// Measured in the iOS 26.5 simulator's Messages at 60 fps: the photo flies
/// on a critically damped spring, faster out of the bubble (omega 26.5 /s)
/// than back into it (omega 19.4 /s, both from the close button and from a
/// released drag). Dragging down shrinks the photo by 1 pt per 1320 pt of
/// travel while the black veil over the transcript fades out over 400 pt.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationPhotoFlight {
    public static let openOmega: Double = 26.5
    public static let closeOmega: Double = 19.4
    /// Within half a point per 400 pt of travel.
    static let settleTolerance: Double = 0.00125

    /// A critically damped spring from 0 to 1.
    public static func progress(at t: Double, omega: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        guard t < settleTime(omega: omega) else { return 1 }
        return CGFloat(1 - (1 + omega * t) * exp(-omega * t))
    }

    /// When the close spring starts. Letting go of a dragged photo, Quick
    /// Look flies it back from the lift itself (one frame later it is 17%
    /// of the way to its bubble), so a recent `lift` is the start; the close
    /// button, or a lift long gone, starts it at the transition's first frame.
    public static func closeStart(lift: Double?, firstFrame: Double) -> Double {
        guard let lift, lift <= firstFrame, firstFrame - lift < 0.25 else { return firstFrame }
        return lift
    }

    /// When the spring is within `settleTolerance` of its end.
    public static func settleTime(omega: Double) -> Double {
        // Solve (1 + x) e^-x = tolerance by Newton's method on x = omega t.
        var x = 8.0
        for _ in 0..<8 {
            let f = (1 + x) * exp(-x) - settleTolerance
            let df = -x * exp(-x)
            x -= f / df
        }
        return x / omega
    }

    /// The photo's scale while dragged `translation` points down.
    public static func dragScale(translation: CGFloat) -> CGFloat {
        max(0.5, 1 - max(0, translation) / 1320)
    }

    /// How much of the viewer (its veil and chrome) shows while dragged.
    public static func dragPresentation(translation: CGFloat) -> CGFloat {
        min(1, max(0, 1 - translation / 400))
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

/// The photo viewer's chrome on each OS.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationPhotoViewerLayout {
    public enum Style: Sendable {
        /// iOS 26: Quick Look's chrome, a "Photo" title with close at the
        /// trailing edge, Tapback and Reply bottom leading, Share bottom trailing.
        case quickLook26
        /// iOS 27 (a real iPhone): close at the leading edge and Share at the
        /// trailing edge of the top bar, nothing else.
        case zoom27
    }

    /// iOS 26 opens on black with the chrome hidden; a tap shows it.
    public static func opensWithChromeHidden(_ style: Style) -> Bool { style == .quickLook26 }
    public static func showsTitle(_ style: Style) -> Bool { style == .quickLook26 }
    public static func showsActions(_ style: Style) -> Bool { style == .quickLook26 }

    public static let buttonSize: CGFloat = 44
    public static let sideInset: CGFloat = 16

    public static func closeFrame(_ style: Style, width: CGFloat, safeTop: CGFloat) -> CGRect {
        switch style {
        case .quickLook26:
            return CGRect(x: width - sideInset - buttonSize, y: safeTop, width: buttonSize, height: buttonSize)
        case .zoom27:
            return CGRect(x: sideInset, y: safeTop + 4, width: buttonSize, height: buttonSize)
        }
    }

    public static func shareFrame(_ style: Style, width: CGFloat, safeTop: CGFloat, bottom: CGFloat) -> CGRect {
        switch style {
        case .quickLook26:
            // 48 pt, centered 52 pt above the bottom edge, 28 pt in.
            return CGRect(x: width - 28 - 48, y: bottom - 52 - 24, width: 48, height: 48)
        case .zoom27:
            return CGRect(x: width - sideInset - buttonSize, y: safeTop + 4, width: buttonSize, height: buttonSize)
        }
    }
}
