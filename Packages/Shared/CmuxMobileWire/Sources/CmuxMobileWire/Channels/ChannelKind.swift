/// What a stream-plane channel carries (a0-rpc.md section 3.4).
public enum ChannelKind: String, CaseIterable, Hashable, Sendable, Codable {
    case rpc
    case terminal
    case browser
    case rd
    case filesUpload = "files.upload"
    case filesDownload = "files.download"
    /// A TCP byte stream to a loopback port of the Mac (c14-web.md section 3).
    case tcpForward = "tcp.forward"
    /// One booted iOS simulator of the Mac, on the browser channel's rd path (c14-web.md section 6).
    case simulator
}
