import Foundation

/// Simulator streaming v2 wire protocol.
///
/// Design invariants (docs/ios-simulator-streaming-v2.md):
/// - One bidirectional QUIC lane per stream. Host -> viewer carries
///   `config`/`frame`/`state`; viewer -> host carries
///   `start`/`ack`/`input`/`keyframeRequest`/`stop`. Both directions are
///   ordered, so no message carries fencing state beyond the frame sequence.
/// - Frames are encoded video (HEVC/H.264), never still images, and are only
///   produced while the viewer has ack credit, so nothing downstream ever
///   queues, sheds, or replays a stale frame.
/// - A stream is (re)established by a single `start` message. Every `start`
///   is answered with `config` followed by a keyframe. There is no other
///   handshake and no state survives a transport drop.
public enum SimStreamProtocol {
    public static let version: UInt8 = 1
    /// Capability token the Mac host advertises when it can serve this lane.
    public static let capability = "simulator.stream.v2"
    /// Upper bound for any single wire message (keyframes included).
    public static let maximumMessageByteCount = 8 * 1024 * 1024
}

public enum SimStreamVideoCodec: UInt8, Sendable, Equatable, CaseIterable {
    case hevc = 0
    case h264 = 1
}

public enum SimStreamOrientation: UInt8, Sendable, Equatable {
    case portrait = 0
    case landscapeLeft = 1
    case portraitUpsideDown = 2
    case landscapeRight = 3
}

/// Host-reported stream status, emitted only on change (never as a clock).
public enum SimStreamHostStatus: UInt8, Sendable, Equatable {
    case preparing = 0
    case streaming = 1
    case deviceUnavailable = 2
    case workerCrashed = 3
    case failed = 4
    case closed = 5
}

public struct SimStreamStartRequest: Sendable, Equatable {
    /// Protocol version the viewer speaks.
    public var version: UInt8
    /// Monotonic viewer-chosen value; a session created by a later epoch
    /// supersedes any session the host still holds for the same panel.
    public var epoch: UInt64
    /// Longest output dimension in pixels the viewer wants (host may clamp).
    public var maximumLongSidePixels: UInt16
    /// Codecs the viewer can decode, most preferred first.
    public var codecPreferences: [SimStreamVideoCodec]

    public init(
        version: UInt8 = SimStreamProtocol.version,
        epoch: UInt64,
        maximumLongSidePixels: UInt16,
        codecPreferences: [SimStreamVideoCodec]
    ) {
        self.version = version
        self.epoch = epoch
        self.maximumLongSidePixels = maximumLongSidePixels
        self.codecPreferences = codecPreferences
    }
}

public struct SimStreamConfig: Sendable, Equatable {
    public var codec: SimStreamVideoCodec
    /// Encoded video dimensions in pixels.
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    /// Simulator screen scale (pixels per point of the streamed content).
    public var displayScale: Float
    public var orientation: SimStreamOrientation
    /// Codec parameter sets (HEVC: VPS/SPS/PPS, H.264: SPS/PPS) exactly as
    /// emitted by the encoder's format description.
    public var parameterSets: [Data]
    /// Length in bytes of the NAL unit length prefixes in frame payloads.
    public var nalUnitHeaderLength: UInt8

    public init(
        codec: SimStreamVideoCodec,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        displayScale: Float,
        orientation: SimStreamOrientation,
        parameterSets: [Data],
        nalUnitHeaderLength: UInt8
    ) {
        self.codec = codec
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayScale = displayScale
        self.orientation = orientation
        self.parameterSets = parameterSets
        self.nalUnitHeaderLength = nalUnitHeaderLength
    }
}

public struct SimStreamFrame: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
    }

    public var sequence: UInt64
    public var flags: Flags
    /// Capture timestamp in microseconds on the host clock; used for
    /// diagnostics and pacing math, never for display scheduling (frames
    /// display immediately).
    public var presentationMicroseconds: UInt64
    /// AVCC/HVCC-formatted encoded frame data (length-prefixed NAL units).
    public var payload: Data

    public init(
        sequence: UInt64,
        flags: Flags,
        presentationMicroseconds: UInt64,
        payload: Data
    ) {
        self.sequence = sequence
        self.flags = flags
        self.presentationMicroseconds = presentationMicroseconds
        self.payload = payload
    }
}

public struct SimStreamAck: Sendable, Equatable {
    /// Highest frame sequence the viewer has decoded and presented.
    public var sequence: UInt64
    /// Viewer receipt timestamp in microseconds on the viewer clock,
    /// echoed for host-side delivery-rate estimation.
    public var receiptMicroseconds: UInt64

    public init(sequence: UInt64, receiptMicroseconds: UInt64) {
        self.sequence = sequence
        self.receiptMicroseconds = receiptMicroseconds
    }
}

public enum SimStreamTouchPhase: UInt8, Sendable, Equatable {
    case began = 0
    case moved = 1
    case ended = 2
    case cancelled = 3
}

public enum SimStreamHardwareButton: UInt8, Sendable, Equatable {
    case home = 0
    case lock = 1
    case siri = 2
    case sideButton = 3
    case appSwitcher = 4
    case volumeUp = 5
    case volumeDown = 6
    case power = 7
    case swipeHome = 8
}

public enum SimStreamInputEvent: Sendable, Equatable {
    /// Normalized [0,1] coordinates in the streamed frame's orientation.
    case touch(
        phase: SimStreamTouchPhase,
        pointerID: UInt8,
        x: Float,
        y: Float,
        timestampMicroseconds: UInt64
    )
    case text(String)
    /// USB HID keyboard usage code with explicit key direction.
    case key(usage: UInt16, isDown: Bool)
    case button(SimStreamHardwareButton)
}

public struct SimStreamInputBatch: Sendable, Equatable {
    /// Monotonic per-stream batch sequence; the host rejects regressions so
    /// duplicated or reordered delivery can never replay input.
    public var sequence: UInt64
    public var events: [SimStreamInputEvent]

    public init(sequence: UInt64, events: [SimStreamInputEvent]) {
        self.sequence = sequence
        self.events = events
    }
}

public struct SimStreamStateUpdate: Sendable, Equatable {
    public var status: SimStreamHostStatus
    public var detail: String

    public init(status: SimStreamHostStatus, detail: String = "") {
        self.status = status
        self.detail = detail
    }
}

public enum SimStreamMessage: Sendable, Equatable {
    case start(SimStreamStartRequest)
    case config(SimStreamConfig)
    case frame(SimStreamFrame)
    case ack(SimStreamAck)
    case input(SimStreamInputBatch)
    case keyframeRequest
    case stop
    case state(SimStreamStateUpdate)
}
