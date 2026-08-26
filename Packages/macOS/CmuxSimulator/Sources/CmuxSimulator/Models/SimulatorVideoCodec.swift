/// A codec accepted by `simctl io recordVideo`.
public enum SimulatorVideoCodec: String, Codable, CaseIterable, Hashable, Sendable {
    /// H.264 video.
    case h264
    /// HEVC video.
    case hevc
}
