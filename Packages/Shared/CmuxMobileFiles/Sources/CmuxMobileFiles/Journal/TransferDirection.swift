/// Which way a transfer moves bytes.
public enum TransferDirection: String, Hashable, Sendable, Codable {
    case upload
    case download
}
