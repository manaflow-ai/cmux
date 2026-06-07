public import Foundation

/// Typed decoder for the `mobile.host.status` RPC result.
///
/// Drives terminal-output transport negotiation: the iOS client prefers the
/// render-grid transport when the Mac either advertises the render-grid
/// capability or reports `terminal_fidelity == "render_grid"`, and otherwise
/// falls back to raw bytes.
public struct MobileHostStatusResponse: Decodable, Sendable {
    /// Capability identifiers the host advertises (for example
    /// `terminal.render_grid.v1`).
    public let capabilities: [String]
    /// The host's reported terminal fidelity (for example `render_grid`), if any.
    public let terminalFidelity: String?

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case terminalFidelity = "terminal_fidelity"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = (try container.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        terminalFidelity = try container.decodeIfPresent(String.self, forKey: .terminalFidelity)
    }

    /// Decode a host-status response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileHostStatusResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
