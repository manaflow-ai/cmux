public import Foundation

/// Decodes the result of `mobile.workspace.changes.context`.
public struct MobileChangesContextResponse: Codable, Sendable, Equatable {
    /// New-side file content for the requested inclusive line range.
    public let rows: [String]

    /// Creates a context-lines response.
    /// - Parameter rows: New-side file content for the requested line range.
    public init(rows: [String]) {
        self.rows = rows
    }

    /// Decodes context lines from an RPC result payload.
    /// - Parameter data: The JSON result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileChangesContextResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
