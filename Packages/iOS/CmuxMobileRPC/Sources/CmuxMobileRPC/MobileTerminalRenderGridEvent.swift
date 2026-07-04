public import CMUXMobileCore
public import Foundation

/// Typed decoder for a `terminal.render_grid` push-event payload that nests the
/// frame under a `render_grid` key.
///
/// Some hosts wrap the frame (`{"render_grid": { ... }}`) and some emit the bare
/// frame as the whole payload. This DTO decodes the wrapped form; the caller
/// falls back to decoding the payload directly as a
/// ``MobileTerminalRenderGridFrame`` when ``frame`` is `nil`.
public struct MobileTerminalRenderGridEvent: Decodable, Sendable {
    /// The nested render-grid frame, if the payload used the wrapped form.
    public let frame: MobileTerminalRenderGridFrame?
    /// Whether matching hybrid raw bytes were suppressed because the host-side
    /// pending byte buffer overflowed before the render-grid flush.
    public let hybridBytesOverflowed: Bool

    private enum CodingKeys: String, CodingKey {
        case frame = "render_grid"
        case hybridBytesOverflowed = "hybrid_bytes_overflowed"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decodeIfPresent(MobileTerminalRenderGridFrame.self, forKey: .frame)
        hybridBytesOverflowed = try container.decodeIfPresent(Bool.self, forKey: .hybridBytesOverflowed) ?? false
    }

    /// Decode a wrapped render-grid event from a raw JSON payload.
    /// - Parameter data: The event payload JSON.
    /// - Returns: The decoded event.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileTerminalRenderGridEvent {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
