/// `input.resampleDrags` and `input.resampleFrameAheadMs` in cmux-next.json: how a dragged divider or
/// edge is drawn (feature `resampledDrags`).
///
/// ```jsonc
/// "input": {
///   "resampleDrags": true,       // draw drags at the pointer resampled at each frame's time
///   "resampleFrameAheadMs": 0    // debug: predict this far ahead of the frame (0: no prediction)
/// }
/// ```
///
/// Resampling moves only what is drawn: snaps, drop zones and the release velocity read the real
/// pointer. Reduce Motion turns it off whatever the setting says.
///
/// Read from the snapshot's document, not stored: a missing or invalid value is the default.
public nonisolated struct DragResampleSettings: Sendable, Equatable {
    public static let resampleDragsPath = ["input", "resampleDrags"]
    public static let frameAheadPath = ["input", "resampleFrameAheadMs"]
    /// Chromium's frame-ahead prediction is off by default; at most one 60 Hz frame here.
    public static let frameAheadRange: ClosedRange<Double> = 0...16
    public static let resampleDragsDefault = true
    public static let frameAheadDefault: Double = 0

    public var resampleDrags = Self.resampleDragsDefault
    public var frameAheadMs = Self.frameAheadDefault

    public init() {}

    /// The values in `root`: a non-boolean `resampleDrags` is the default, a non-number or
    /// out-of-range `resampleFrameAheadMs` is the default.
    public init(_ root: JSONValue) {
        if let value = root.value(at: Self.resampleDragsPath)?.boolValue { resampleDrags = value }
        if let value = root.value(at: Self.frameAheadPath)?.doubleValue, Self.frameAheadRange.contains(value) {
            frameAheadMs = value
        }
    }
}

extension CmuxConfigSnapshot {
    /// `input.resampleDrags` and `input.resampleFrameAheadMs` (``DragResampleSettings``).
    public var dragResampling: DragResampleSettings { DragResampleSettings(root) }
}
