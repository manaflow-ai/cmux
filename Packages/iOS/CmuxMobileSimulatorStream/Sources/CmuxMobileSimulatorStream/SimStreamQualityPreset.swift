/// Viewer-selectable resolution caps for the stream.
///
/// The cap bounds the encode size on the Mac; bitrate keeps adapting to the
/// link separately. Lower caps trade sharpness for less data and faster
/// per-frame encode/decode; end-to-end latency is otherwise unchanged
/// because pacing (encode-on-credit) already prevents queue buildup at any
/// resolution.
public enum SimStreamQualityPreset: String, CaseIterable, Sendable {
    /// Near-native pixels; sharpest text, most data.
    case high
    /// Fits modern phone screens; visually close to high at half the data.
    case balanced
    /// For constrained links; soft text, lowest data and decode cost.
    case dataSaver

    public var maximumLongSidePixels: UInt16 {
        switch self {
        case .high: 2_000
        case .balanced: 1_280
        case .dataSaver: 800
        }
    }

    public static let `default` = SimStreamQualityPreset.high
}
