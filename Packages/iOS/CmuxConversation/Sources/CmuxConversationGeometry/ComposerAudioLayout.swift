import CoreGraphics

/// The composer row while an audio message is recorded or reviewed, as
/// Messages draws it on iOS 26 (read at @3x, frame by frame, from a screen
/// recording of Messages on a 430 pt iPhone, 2026-11-09).
///
/// Messages' sequence, which this layout follows stage by stage:
/// - `holding`: the finger is down on the record glyph. The field lifts to
///   50 pt, reaches 7.67 pt past its trailing end and over the gap to the
///   "+" (the two glass shapes merge); a solid red stop button replaces the
///   glyph, red silence dots fill the field, the timer reads 0:00.
/// - `recording`: the finger lifted and the recording carries on. The field
///   swallows the "+" and grows to 68.67 pt tall, 5.33 pt past the "+"'s
///   leading edge and 8 pt past the field's end; the stop button dims.
/// - `review`: stop was tapped. The field returns to its resting width at
///   66.33 pt tall; an "x" circle takes the "+"'s place, centered on the
///   field; inside, a play circle, the waveform, a "+ 0:03" continue pill
///   and the send capsule, all on the field's middle line.
public struct ComposerAudioLayout: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case holding
        case recording
        case review
    }

    /// The field, in the row's coordinates.
    public var field: CGRect
    /// The "+" circle (hidden in `recording`, the "x" in `review`).
    public var leadingButton: CGRect
    /// Whether the "+" / "x" circle shows.
    public var showsLeadingButton: Bool
    /// The stop circle (`holding`, `recording`) in the field's coordinates.
    public var stop: CGRect
    /// The stop square, in the stop circle's coordinates.
    public var stopSquare: CGRect
    /// The timer's trailing edge and middle line, in the field's coordinates.
    public var timerTrailing: CGFloat
    /// The waveform band (bar centers on its middle), in the field's coordinates.
    public var waveform: CGRect
    /// The play circle (`review`), in the field's coordinates.
    public var play: CGRect
    /// The send capsule (`review`), in the field's coordinates.
    public var send: CGRect
    /// The field's middle line, in the field's coordinates.
    public var midY: CGFloat

    // Messages' metrics (pt).
    public static let holdingHeight: CGFloat = 50
    public static let recordingHeight: CGFloat = 68 + 2.0 / 3
    public static let reviewHeight: CGFloat = 66 + 1.0 / 3
    /// How far the held field reaches past its resting trailing end.
    public static let holdingTrailingReach: CGFloat = 7 + 2.0 / 3
    /// The held field starts 4 pt after the "+" (72 pt on a 430 pt row).
    public static let holdingLeadingGap: CGFloat = 4
    /// How far the recording field reaches past the "+"'s leading edge and the resting end.
    public static let recordingLeadingReach: CGFloat = 5 + 1.0 / 3
    public static let recordingTrailingReach: CGFloat = 8
    /// Stop: a 35.67 pt circle with an 11.33 pt square, centered in the
    /// field's end cap (34.33 pt in from a recording field's end, 24.83 held).
    public static let stopDiameter: CGFloat = 35 + 2.0 / 3
    public static let stopSquareSide: CGFloat = 11 + 1.0 / 3
    public static let stopSquareCornerRadius: CGFloat = 2.5
    /// Gap from the timer's last digit to the stop circle.
    public static let timerToStop: CGFloat = 14
    /// The waveform starts 24.67 pt into the recording field and stops 15.33 pt before the timer.
    public static let recordingWaveLeading: CGFloat = 24 + 2.0 / 3
    public static let waveToTimer: CGFloat = 15 + 1.0 / 3
    /// Width reserved for the timer ("0:00" to "9:59" at 14 pt).
    public static let timerWidth: CGFloat = 27
    /// Review: play circle 34.33 pt, 16.67 pt from the field's leading edge;
    /// waveform 16 pt after it; pill 59 by 25.33 pt; send 38 by 28, 19.33 pt
    /// from the field's end; 12.33 pt gaps between waveform, pill and send.
    public static let playDiameter: CGFloat = 34 + 1.0 / 3
    public static let playLeading: CGFloat = 16 + 2.0 / 3
    public static let playToWave: CGFloat = 16
    public static let pillSize = CGSize(width: 59, height: 25 + 1.0 / 3)
    public static let reviewGap: CGFloat = 12 + 1.0 / 3
    public static let reviewSendTrailing: CGFloat = 19 + 1.0 / 3
    /// The waveform's bars: 2 pt wide on a 4 pt pitch; silence draws 4 pt tall dots.
    public static let barWidth: CGFloat = 2
    public static let barPitch: CGFloat = 4
    public static let silenceBarHeight: CGFloat = 4
    public static let maxBarHeight: CGFloat = 24

    /// Lays out `stage` for a row of `width`, given the resting layout's
    /// "+" and field (`ComposerBarGeometry.layout`) and the side inset.
    public init(stage: Stage, resting: ComposerBarGeometry.Layout, width: CGFloat, sideInset: CGFloat, scale: CGFloat) {
        let bottom = resting.field.maxY
        let restingEnd = width - sideInset
        switch stage {
        case .holding:
            let minX = resting.plus.maxX + Self.holdingLeadingGap
            field = CGRect(x: minX, y: bottom - Self.holdingHeight, width: restingEnd + Self.holdingTrailingReach - minX, height: Self.holdingHeight)
        case .recording:
            let minX = resting.plus.minX - Self.recordingLeadingReach
            field = CGRect(x: minX, y: bottom - Self.recordingHeight, width: restingEnd + Self.recordingTrailingReach - minX, height: Self.recordingHeight)
        case .review:
            field = CGRect(x: resting.field.minX, y: bottom - Self.reviewHeight, width: restingEnd - resting.field.minX, height: Self.reviewHeight)
        }
        let mid = field.height / 2
        midY = mid
        showsLeadingButton = stage != .recording
        if stage == .review {
            let side = resting.plus.width
            leadingButton = Self.pixelRound(CGRect(x: resting.plus.minX, y: field.midY - side / 2, width: side, height: side), scale: scale)
        } else {
            leadingButton = resting.plus
        }
        let stopCenterX = field.width - field.height / 2
        stop = Self.pixelRound(CGRect(x: stopCenterX - Self.stopDiameter / 2, y: mid - Self.stopDiameter / 2, width: Self.stopDiameter, height: Self.stopDiameter), scale: scale)
        let squareInset = (Self.stopDiameter - Self.stopSquareSide) / 2
        stopSquare = CGRect(x: squareInset, y: squareInset, width: Self.stopSquareSide, height: Self.stopSquareSide)
        timerTrailing = stop.minX - Self.timerToStop
        play = Self.pixelRound(CGRect(x: Self.playLeading, y: mid - Self.playDiameter / 2, width: Self.playDiameter, height: Self.playDiameter), scale: scale)
        let sendSize = ComposerBarGeometry.sendSize
        send = Self.pixelRound(CGRect(x: field.width - Self.reviewSendTrailing - sendSize.width, y: mid - sendSize.height / 2, width: sendSize.width, height: sendSize.height), scale: scale)
        let band = Self.maxBarHeight
        switch stage {
        case .holding, .recording:
            // Both start 24.67 pt into the field (held: 96 pt on a field at 72).
            let leading = Self.recordingWaveLeading
            let trailing = timerTrailing - Self.timerWidth - Self.waveToTimer
            waveform = CGRect(x: leading, y: mid - band / 2, width: max(0, trailing - leading), height: band)
        case .review:
            let leading = play.maxX + Self.playToWave
            let trailing = send.minX - Self.reviewGap - Self.pillSize.width - Self.reviewGap
            waveform = CGRect(x: leading, y: mid - band / 2, width: max(0, trailing - leading), height: band)
        }
    }

    /// The continue pill ("+ 0:03"), in the field's coordinates.
    public var pill: CGRect {
        CGRect(x: send.minX - Self.reviewGap - Self.pillSize.width, y: midY - Self.pillSize.height / 2, width: Self.pillSize.width, height: Self.pillSize.height)
    }

    /// Whole bars that fit `width` on the 4 pt pitch.
    public static func barCount(width: CGFloat) -> Int {
        max(0, Int(((width + barPitch - barWidth) / barPitch).rounded(.down)))
    }

    /// A bar's height for a 0...1 level: silence is a 4 pt dot.
    public static func barHeight(level: Float, band: CGFloat) -> CGFloat {
        let level = CGFloat(min(1, max(0, level)))
        return max(silenceBarHeight, (level * min(maxBarHeight, band)).rounded())
    }

    static func pixelRound(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        return CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale, width: rect.width, height: rect.height)
    }
}
