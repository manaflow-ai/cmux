public import Foundation

/// The video codec of a stream (`remoteDesktop.codec` picks it at session
/// setup; AV1 is phase 4 and has no decoder path here yet).
public nonisolated enum RemoteVideoCodec: String, Sendable, Hashable, CaseIterable, Codable {
    case h264
    case hevc
}

/// Frame flags from the `cmux.rd/1` datagram header (cmux-rd-proto
/// `flags`): the same bit values, so a transport can pass the byte through.
public nonisolated struct RemoteFrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// An IDR: the frame references no earlier frame.
    public static let keyframe = RemoteFrameFlags(rawValue: 0b0001)
    /// The frame re-encodes a static screen at higher quality.
    public static let refine = RemoteFrameFlags(rawValue: 0b0010)
    /// The frame recovers from a loss by referencing an acknowledged frame.
    public static let recovery = RemoteFrameFlags(rawValue: 0b0100)
    /// A lossless tile top-off on a tile stream (rd change C3); not H.264.
    public static let tile = RemoteFrameFlags(rawValue: 0b1000)
}

/// One complete access unit, reassembled by the transport and ready to
/// decode: Annex-B bytes (start codes, with VPS/SPS/PPS before keyframes)
/// exactly as the host's encoder produced them.
public nonisolated struct RemoteAccessUnit: Sendable, Hashable {
    /// Host frame number; consecutive within one stream. A gap means frames
    /// were lost and later non-key frames must not be shown.
    public var frame: UInt32
    public var flags: RemoteFrameFlags
    /// Host monotonic capture time in microseconds (frame body prefix).
    public var tCaptureMicros: UInt64
    /// Annex-B H.264 or HEVC.
    public var data: Data
    public var codec: RemoteVideoCodec

    public init(frame: UInt32, flags: RemoteFrameFlags, tCaptureMicros: UInt64, data: Data, codec: RemoteVideoCodec) {
        self.frame = frame
        self.flags = flags
        self.tCaptureMicros = tCaptureMicros
        self.data = data
        self.codec = codec
    }

    public var isKeyframe: Bool { flags.contains(.keyframe) }
}
