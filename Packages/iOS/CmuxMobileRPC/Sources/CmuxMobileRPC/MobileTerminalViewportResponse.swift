public import Foundation

/// Typed decoder for the `mobile.terminal.viewport` RPC result.
///
/// The Mac returns the effective shared grid it computed across every attached
/// device (the smallest cols×rows, capped to the Mac pane). The iOS client pins
/// its libghostty surface to that grid so every device renders identically.
/// Both fields must be present and positive for the response to be usable; a
/// missing or non-positive value is treated as "no effective grid".
public struct MobileTerminalViewportResponse: Decodable, Sendable {
    /// The effective shared column count, if reported.
    public let columns: Int?
    /// The effective shared row count, if reported.
    public let rows: Int?

    private enum CodingKeys: String, CodingKey {
        case columns
        case rows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
    }

    /// The effective grid when both dimensions are present and positive.
    ///
    /// - Returns: A `(columns, rows)` pair, or `nil` when either dimension is
    ///   missing or not positive.
    public var effectiveGrid: (columns: Int, rows: Int)? {
        guard let columns, let rows, columns > 0, rows > 0 else { return nil }
        return (columns, rows)
    }

    /// Decode a viewport response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileTerminalViewportResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
