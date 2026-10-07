/// Header flag bits (low nibble of the first header byte).
public struct RdFrameFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// An IDR: references no earlier frame.
    public static let keyframe = RdFrameFlags(rawValue: 0b0001)
    /// Re-encodes a static screen at higher quality.
    public static let refine = RdFrameFlags(rawValue: 0b0010)
    /// Recovers from loss by referencing an acknowledged frame.
    public static let recovery = RdFrameFlags(rawValue: 0b0100)
    /// Lossless tile top-off (cap `tile`).
    public static let tile = RdFrameFlags(rawValue: 0b1000)

    public static let all: RdFrameFlags = [.keyframe, .refine, .recovery, .tile]
}
