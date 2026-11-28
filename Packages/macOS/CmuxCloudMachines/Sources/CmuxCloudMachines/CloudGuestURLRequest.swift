import Foundation

/// A transient request to open a web URL on a frontend projecting the source terminal.
/// The request ID is an opaque acknowledgement capability, never a durable resource ID.
public struct CloudGuestURLRequest: Sendable, Equatable, Decodable {
    /// Daemon event discriminator; only `url-open` is accepted.
    public let event: String
    /// Random capability used to claim and acknowledge this single request.
    public let requestID: String
    /// The guest terminal whose projection determines the destination workspace.
    public let terminalID: String
    /// Original URL bytes, including the case and percent encoding of auth parameters.
    public let url: String

    private enum CodingKeys: String, CodingKey {
        case event, url
        case requestID = "request_id"
        case terminalID = "terminal_id"
    }

    /// Decodes bounded, HTTP(S)-only wire data without normalizing authentication parameters.
    public init?(data: Data) {
        guard data.count <= 20_000,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.event == "url-open",
              UUID(uuidString: value.requestID) != nil,
              value.terminalID.hasPrefix("term_"), value.terminalID.count == 37,
              value.terminalID.dropFirst(5).allSatisfy({ $0.isHexDigit }),
              value.url.utf8.count <= 16_384,
              !value.url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let url = URL(string: value.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        self = value
    }
}
