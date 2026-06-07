public import CMUXMobileCore
public import Foundation

/// Typed decoder for the `mobile.terminal.replay` RPC result.
///
/// Cold-attach / self-heal replay. The Mac prefers a bounded render-grid
/// snapshot (``renderGrid``); a base64 VT snapshot (``snapshotBase64``) and a
/// base64 raw byte tail (``dataBase64``) remain compatibility fallbacks for
/// older hosts. ``sequence`` carries the explicit end sequence when the host
/// reports one outside the render grid.
public struct MobileTerminalReplayResponse: Decodable, Sendable {
    /// Base64-encoded raw byte tail, the lowest-fidelity fallback.
    public let dataBase64: String?
    /// Base64-encoded VT snapshot, the mid-fidelity fallback.
    public let snapshotBase64: String?
    /// The render-grid snapshot frame, the preferred replay payload.
    public let renderGrid: MobileTerminalRenderGridFrame?
    /// The host's explicit end sequence, used when no render grid is present.
    public let sequence: UInt64?
    /// The host grid column count (debug diagnostics only).
    public let columns: Int?
    /// The host grid row count (debug diagnostics only).
    public let rows: Int?

    private enum CodingKeys: String, CodingKey {
        case dataBase64 = "data_b64"
        case snapshotBase64 = "snapshot_data_b64"
        case renderGrid = "render_grid"
        case sequence = "seq"
        case columns
        case rows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataBase64 = try container.decodeIfPresent(String.self, forKey: .dataBase64)
        snapshotBase64 = try container.decodeIfPresent(String.self, forKey: .snapshotBase64)
        // A malformed render_grid must not fail the whole replay; the legacy
        // path used `try?` on the sub-object decode, so mirror that tolerance.
        renderGrid = try? container.decodeIfPresent(MobileTerminalRenderGridFrame.self, forKey: .renderGrid)
        sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
    }

    /// Decode a replay response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileTerminalReplayResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
