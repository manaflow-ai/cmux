/// Result of encoding one key against the backend's canonical terminal modes.
public struct BackendTerminalKeyResponse: Decodable, Equatable, Sendable {
    /// Bytes written to the PTY. Releases can validly encode zero bytes.
    public let encodedBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case encodedBytes = "encoded_bytes"
    }
}
