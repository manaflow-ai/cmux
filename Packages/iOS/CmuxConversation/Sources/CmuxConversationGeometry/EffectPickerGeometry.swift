import CoreGraphics

/// "Send with effect" as Messages lays it out (CKEffectPickerStandardView,
/// identical on iOS 26.5 and 27.0): everything hangs off the send button
/// where the long press found it, keyboard up or down. The cancel button
/// takes the send button's place; above it a white capsule track (54 pt
/// wide, 215 tall, 25 pt over the send button) holds the four bubble
/// effects' 38 pt dots at a 57 pt pitch, their names end 22 pt left of the
/// track, and the draft bubble ends 20 pt left of it, its body ending 8.33
/// pt over the cancel button's bottom.
public struct EffectPickerGeometry: Equatable, Sendable {
    public static let dotSize: CGFloat = 38
    public static let dotPitch: CGFloat = 57
    public static let trackInset: CGFloat = 8
    public static let trackPadding: CGFloat = 3
    public static let trackGap: CGFloat = 25
    public static let trackCornerRadius: CGFloat = 22
    public static let labelGap: CGFloat = 22
    public static let bubbleGap: CGFloat = 20

    public let cancel: CGRect
    public let track: CGRect
    public let dots: [CGRect]
    public let labelTrailing: CGFloat
    public let title: CGRect
    public let segments: CGRect

    public init(sendButton: CGRect, width: CGFloat, safeTop: CGFloat, effectCount: Int = 4) {
        cancel = sendButton
        let count = CGFloat(max(1, effectCount))
        let height = 2 * Self.trackPadding + count * Self.dotSize + (count - 1) * (Self.dotPitch - Self.dotSize)
        track = CGRect(
            x: sendButton.minX - Self.trackInset,
            y: sendButton.minY - Self.trackGap - height,
            width: sendButton.width + 2 * Self.trackInset,
            height: height
        )
        dots = (0..<max(1, effectCount)).map { [track] index in
            CGRect(x: sendButton.minX, y: track.minY + Self.trackPadding + CGFloat(index) * Self.dotPitch, width: Self.dotSize, height: Self.dotSize)
        }
        labelTrailing = track.minX - Self.labelGap
        title = CGRect(x: 20, y: safeTop + 29, width: width - 40, height: 26.33)
        segments = CGRect(x: (width - 240) / 2, y: safeTop + 70, width: 240, height: 32)
    }

    /// The draft bubble before an effect is picked: `size` is its body
    /// (with the tail's width), whose bottom sits 8.33 pt over the cancel
    /// button's (Messages 27.0: body 476 ... 515.67 beside a cancel ending at 524).
    public func homeBubble(size: CGSize) -> CGRect {
        CGRect(x: track.minX - Self.bubbleGap - size.width, y: cancel.maxY - 8.33 - size.height, width: size.width, height: size.height)
    }

    /// The draft bubble beside the picked effect's dot (Messages 27.0: Slam
    /// picked, bubble {204.09, 260.5} ending 5.5 pt left of the track).
    public func pickedBubble(size: CGSize, index: Int) -> CGRect {
        let dot = dots[max(0, min(index, dots.count - 1))]
        return CGRect(x: track.minX - 5.5 - size.width, y: dot.minY + 1.5, width: size.width, height: size.height)
    }

    /// The picked effect's "SEND WITH …" name rides above the bubble: its
    /// center 13 pt over the bubble's top.
    public static func pickedLabelCenterY(bubble: CGRect) -> CGFloat { bubble.minY - 13 }
}
