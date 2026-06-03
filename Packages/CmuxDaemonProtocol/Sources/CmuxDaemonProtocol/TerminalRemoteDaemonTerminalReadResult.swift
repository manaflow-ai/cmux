public import Foundation

/// A window of decoded terminal output read from a daemon session.
///
/// The wire encodes ``data`` as a base64 string; this type decodes it into raw
/// bytes. Returned by ``DaemonRPCMethod/terminalRead`` and the initial
/// ``DaemonRPCMethod/terminalSubscribe`` response.
public struct TerminalRemoteDaemonTerminalReadResult: Decodable, Equatable, Sendable {
    /// The session identifier.
    public let sessionID: String
    /// The byte offset immediately past the returned data.
    public let offset: UInt64
    /// The byte offset of the oldest data currently retained by the daemon.
    public let baseOffset: UInt64
    /// Whether the daemon truncated older data before ``baseOffset``.
    public let truncated: Bool
    /// Whether the session has reached end-of-file.
    public let eof: Bool
    /// The decoded output bytes.
    public let data: Data

    /// Creates a terminal-read result value.
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - offset: The byte offset immediately past the returned data.
    ///   - baseOffset: The byte offset of the oldest retained data.
    ///   - truncated: Whether older data was truncated.
    ///   - eof: Whether the session reached end-of-file.
    ///   - data: The decoded output bytes.
    public init(
        sessionID: String,
        offset: UInt64,
        baseOffset: UInt64,
        truncated: Bool,
        eof: Bool,
        data: Data
    ) {
        self.sessionID = sessionID
        self.offset = offset
        self.baseOffset = baseOffset
        self.truncated = truncated
        self.eof = eof
        self.data = data
    }

    /// Decodes a read result, converting the base64-encoded `data` field into raw bytes.
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A `DecodingError` if a required field is missing or `data` is not valid base64.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        offset = try container.decode(UInt64.self, forKey: .offset)
        baseOffset = try container.decode(UInt64.self, forKey: .baseOffset)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        eof = try container.decode(Bool.self, forKey: .eof)

        let encodedData = try container.decode(String.self, forKey: .data)
        guard let decodedData = Data(base64Encoded: encodedData) else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "terminal.read data was not valid base64"
            )
        }
        data = decodedData
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case offset
        case baseOffset = "base_offset"
        case truncated
        case eof
        case data
    }
}
