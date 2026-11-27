/// The owning Mac's pane tree, including tab order and divider positions.
public indirect enum DeviceWorkspaceLayoutNode: Codable, Equatable, Sendable {
    /// The direction in which a split arranges its children.
    public enum Direction: String, Codable, Sendable {
        /// Children appear side by side.
        case horizontal
        /// Children appear one above the other.
        case vertical
    }

    /// A pane's stable identity, ordered surface IDs, and selected surface.
    case pane(id: String, surfaceIDs: [String], selectedSurfaceID: String?)
    /// Two child trees and the first child's share of their available space.
    case split(direction: Direction, ratio: Double, first: DeviceWorkspaceLayoutNode, second: DeviceWorkspaceLayoutNode)

    private enum CodingKeys: String, CodingKey {
        case type, direction, ratio, first, second
        case paneID = "pane_id"
        case surfaceIDs = "surface_ids"
        case selectedSurfaceID = "selected_surface_id"
    }

    /// Decodes the pane/split wire representation.
    /// - Parameter decoder: The decoder for one node and its descendants.
    /// - Throws: A decoding error for an unknown node or missing required fields.
    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 64 else {
            throw DeviceWorkspaceLayoutValidationError.limitExceeded
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "pane":
            self = .pane(
                id: try values.decode(String.self, forKey: .paneID),
                surfaceIDs: try values.decode([String].self, forKey: .surfaceIDs),
                selectedSurfaceID: try values.decodeIfPresent(String.self, forKey: .selectedSurfaceID)
            )
        case "split":
            self = .split(
                direction: try values.decode(Direction.self, forKey: .direction),
                ratio: try values.decode(Double.self, forKey: .ratio),
                first: try values.decode(Self.self, forKey: .first),
                second: try values.decode(Self.self, forKey: .second)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown workspace layout node")
        }
    }

    /// Encodes this node without local paths, commands, or renderer state.
    /// - Parameter encoder: The encoder receiving the node and its descendants.
    /// - Throws: An encoding error if a node cannot be represented.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id, let surfaceIDs, let selectedSurfaceID):
            try values.encode("pane", forKey: .type)
            try values.encode(id, forKey: .paneID)
            try values.encode(surfaceIDs, forKey: .surfaceIDs)
            try values.encodeIfPresent(selectedSurfaceID, forKey: .selectedSurfaceID)
        case .split(let direction, let ratio, let first, let second):
            try values.encode("split", forKey: .type)
            try values.encode(direction, forKey: .direction)
            try values.encode(ratio, forKey: .ratio)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
        }
    }
}
