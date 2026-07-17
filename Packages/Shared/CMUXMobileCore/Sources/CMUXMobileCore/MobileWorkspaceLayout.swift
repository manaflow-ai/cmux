import Foundation

/// A node in the pane-and-tab layout of a mobile workspace.
public indirect enum MobileWorkspaceLayoutNode: Codable, Equatable, Sendable {
    /// The direction in which a split arranges its two children.
    public enum Orientation: String, Codable, Equatable, Sendable {
        /// The children are arranged from left to right.
        case horizontal
        /// The children are arranged from top to bottom.
        case vertical
    }

    /// A split with two child layout nodes.
    case split(
        orientation: Orientation,
        ratio: Double,
        first: MobileWorkspaceLayoutNode,
        second: MobileWorkspaceLayoutNode
    )

    /// A pane containing an ordered stack of tabs and its current selection.
    case pane(
        paneID: String,
        tabs: [MobileWorkspaceLayoutTab],
        selectedTabID: String?
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case orientation
        case ratio
        case first
        case second
        case paneID = "pane_id"
        case tabs
        case selectedTabID = "selected_tab_id"
    }

    /// Decodes a flattened, discriminator-based workspace layout node.
    ///
    /// - Parameter decoder: The decoder supplying the layout node.
    /// - Throws: A decoding error when the discriminator or case fields are invalid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "split":
            self = .split(
                orientation: try container.decode(Orientation.self, forKey: .orientation),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(Self.self, forKey: .first),
                second: try container.decode(Self.self, forKey: .second)
            )
        case "pane":
            self = .pane(
                paneID: try container.decode(String.self, forKey: .paneID),
                tabs: try container.decode([MobileWorkspaceLayoutTab].self, forKey: .tabs),
                selectedTabID: try container.decodeIfPresent(String.self, forKey: .selectedTabID)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown mobile workspace layout node type: \(type)"
            )
        }
    }

    /// Encodes the node with a `type` discriminator and flattened case fields.
    ///
    /// - Parameter encoder: The encoder receiving the layout node.
    /// - Throws: An encoding error when a case field cannot be encoded.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .split(orientation, ratio, first, second):
            try container.encode("split", forKey: .type)
            try container.encode(orientation, forKey: .orientation)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        case let .pane(paneID, tabs, selectedTabID):
            try container.encode("pane", forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(tabs, forKey: .tabs)
            if let selectedTabID {
                try container.encode(selectedTabID, forKey: .selectedTabID)
            } else {
                try container.encodeNil(forKey: .selectedTabID)
            }
        }
    }
}

/// A tab exposed in a mobile workspace layout pane.
public struct MobileWorkspaceLayoutTab: Codable, Equatable, Sendable {
    /// The panel UUID shared with the workspace's flat terminal rows.
    public let id: String
    /// The panel category: `terminal`, `browser`, or `other`.
    public let kind: String
    /// The resolved title shown for the panel on the Mac.
    public let title: String

    /// Creates a mobile workspace layout tab.
    ///
    /// - Parameters:
    ///   - id: The panel UUID shared with other mobile workspace payloads.
    ///   - kind: The panel category: `terminal`, `browser`, or `other`.
    ///   - title: The resolved title shown for the panel on the Mac.
    public init(id: String, kind: String, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
    }
}
