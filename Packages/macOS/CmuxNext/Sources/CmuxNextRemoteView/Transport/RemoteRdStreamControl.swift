import Foundation

/// What a stream carries (`stream_open`), the Rust `StreamKind`. A kind this
/// build does not know parses as `unknown`, so a newer peer's message does
/// not end the session.
public nonisolated enum RemoteRdStreamKind: String, Sendable, Hashable, Codable {
    case video
    case audio
    case tiles
    case popup
    /// Viewer to host: microphone (rd change C4).
    case upAudio = "up_audio"
    /// Viewer to host: camera or screen share (rd change C4).
    case upVideo = "up_video"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteRdStreamKind(rawValue: raw) ?? .unknown
    }

    /// Media the viewer sends to the host.
    public var isUpstream: Bool { self == .upAudio || self == .upVideo }
}

/// `stream_open`: opens stream `stream` (rd changes C3, C4, C6). The viewer
/// sends it only when welcome lists `stream.open`, and an upstream kind only
/// with `up_media` and after the user's consent for that kind.
public nonisolated struct RemoteRdStreamOpen: Sendable, Equatable, Codable {
    public var stream: UInt16
    public var kind: RemoteRdStreamKind
    /// `opus` for audio, `h264` for video.
    public var codec: String
    /// A tile stream's surface stream (C3).
    public var of: UInt16?

    public init(stream: UInt16, kind: RemoteRdStreamKind, codec: String, of: UInt16? = nil) {
        self.stream = stream
        self.kind = kind
        self.codec = codec
        self.of = of
    }
}
