/// Video codecs a browser stream may use (`rb/1` codec names).
public enum BrowserVideoCodec: String, Hashable, Sendable, CaseIterable {
    case h264
    case hevc
}
