public import Foundation

/// Typed decoder for a `terminal.set_font` push-event payload.
///
/// The Mac emits this event to live-resize the mirrored terminal font on
/// connected iOS device(s); the grid reflows automatically once the new point
/// size is applied. The payload carries the absolute point size and an optional
/// `surface_id` / `workspace_id` scope.
public struct MobileTerminalSetFontEvent: Decodable, Sendable {
    /// Absolute terminal font size in points. The iOS surface clamps this to its
    /// supported zoom range before applying.
    public let fontSize: Double
    /// Optional terminal surface scope. When absent, the event may target a
    /// workspace or every mounted terminal surface.
    public let surfaceID: String?
    /// Optional workspace scope used when the event should update every mounted
    /// terminal surface for one workspace.
    public let workspaceID: String?

    private enum CodingKeys: String, CodingKey {
        case fontSize = "font_size"
        case surfaceID = "surface_id"
        case workspaceID = "workspace_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
    }

    /// Decode a set-font event from a raw JSON payload.
    /// - Parameter data: The event payload JSON.
    /// - Returns: The decoded event.
    /// - Throws: A decoding error if the payload is not a JSON object or is
    ///   missing `font_size`.
    public static func decode(_ data: Data) throws -> MobileTerminalSetFontEvent {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
