import Foundation

/// A transient request to preview one remote file beside the guest terminal that sent it.
///
/// The path stays an opaque remote path. It must never be interpreted as a Mac path.
public struct CloudGuestFilePreviewRequest: Sendable, Equatable, Decodable {
    /// Random capability used to claim and acknowledge this single request.
    public let requestID: String
    /// The guest terminal whose unique projection determines the destination workspace.
    public let terminalID: String
    /// Absolute path on the remote host.
    public let path: String
    /// Optional one-based line requested by the guest.
    public let line: Int?

    private enum CodingKeys: String, CodingKey {
        case path, line
        case requestID = "request_id"
        case terminalID = "terminal_id"
    }

    /// Decodes bounded file-preview wire data without normalizing the remote path.
    public init?(data: Data) {
        guard data.count <= 20_000,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["event"] as? String == "file-preview-open",
              UUID(uuidString: value.requestID) != nil,
              value.terminalID.hasPrefix("term_"), value.terminalID.count == 37,
              value.terminalID.dropFirst(5).allSatisfy({ $0.isHexDigit }),
              value.path.utf8.count <= 16_384,
              value.path.hasPrefix("/"),
              !value.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value.line.map({ $0 >= 1 }) ?? true else { return nil }
        self = value
    }
}
