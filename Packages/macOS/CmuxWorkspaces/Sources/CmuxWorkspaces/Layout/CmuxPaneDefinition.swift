/// A leaf pane in the declarative layout tree.
///
/// Holds one or more ``CmuxSurfaceDefinition`` values in declaration order.
/// Decoding rejects an empty surface list.
public struct CmuxPaneDefinition: Codable, Sendable {
    /// The surfaces stacked in this pane, in declaration order.
    public var surfaces: [CmuxSurfaceDefinition]

    /// Creates a pane definition holding the given surfaces.
    public init(surfaces: [CmuxSurfaceDefinition]) {
        self.surfaces = surfaces
    }

    /// Decodes a pane, requiring at least one surface.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaces = try container.decode([CmuxSurfaceDefinition].self, forKey: .surfaces)
        if surfaces.isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Pane node must contain at least one surface"
                )
            )
        }
    }
}
