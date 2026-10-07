/// What a stream-plane channel carries (a0-rpc.md section 3.4).
public enum ChannelKind: String, CaseIterable, Hashable, Sendable, Codable {
    case rpc
    case terminal
    case browser
    case rd
    case filesUpload = "files.upload"
    case filesDownload = "files.download"
}
