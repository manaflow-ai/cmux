public import Foundation

/// Typed decoder for a `terminal.set_font` push-event payload.
///
/// The Mac emits this event to live-resize the mirrored terminal font on
/// connected iOS device(s). The payload carries the absolute point size and an
/// optional `surface_id` / `workspace_id` scope.
public struct MobileTerminalSetFontEvent: Decodable, Sendable {
    public let fontSize: Double
    public let surfaceID: String?
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

    public static func decode(_ data: Data) throws -> MobileTerminalSetFontEvent {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
