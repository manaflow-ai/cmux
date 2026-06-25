public import Bonsplit

/// The `cmux.json` custom-layout wire node: either a leaf `pane` or a binary
/// `split`.
///
/// This is the `Codable`, `Sendable` value image of a `layout` block in
/// `cmux.json`. It owns the on-disk wire format (the decode rules that reject a
/// split with anything other than two children, and the `pane`/`direction`
/// mutual exclusion). ``WorkspaceLayoutCoordinator`` does not walk this type
/// directly: ``CmuxLayoutNode/workspaceCustomLayoutNode`` maps it onto the
/// already-resolved package value ``WorkspaceCustomLayoutNode`` at the
/// `applyCustomLayout` boundary.
///
/// Decode/encode are byte-identical to the original app-target definition: the
/// two-children rule, the non-empty-surfaces rule, and the `clampedSplitPosition`
/// clamp are preserved exactly.
public indirect enum CmuxLayoutNode: Codable, Sendable {
    /// A leaf pane holding one or more surfaces.
    case pane(CmuxPaneDefinition)
    /// A split with exactly two children and an orientation.
    case split(CmuxSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasPane = container.contains(.pane)
        let hasDirection = container.contains(.direction)

        if hasPane && hasDirection {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "CmuxLayoutNode must not contain both 'pane' and 'direction' keys"
                )
            )
        }

        if hasPane {
            let pane = try container.decode(CmuxPaneDefinition.self, forKey: .pane)
            self = .pane(pane)
        } else if hasDirection {
            let splitDef = try CmuxSplitDefinition(from: decoder)
            self = .split(splitDef)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "CmuxLayoutNode must contain either a 'pane' key or a 'direction' key"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}

/// A binary split node in a `cmux.json` custom layout: an orientation, an
/// optional divider position, and exactly two children.
public struct CmuxSplitDefinition: Codable, Sendable {
    /// The split orientation (`horizontal` or `vertical`).
    public var direction: CmuxSplitDirection
    /// The raw divider position in `0...1`, or `nil` for the default `0.5`. Read
    /// through ``clampedSplitPosition`` for the clamped value the layout walk uses.
    public var split: Double?
    /// Exactly two child nodes, in declaration order.
    public var children: [CmuxLayoutNode]

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    /// Creates a split definition. Callers are responsible for supplying exactly
    /// two children; the two-children invariant is enforced on decode.
    public init(direction: CmuxSplitDirection, split: Double? = nil, children: [CmuxLayoutNode]) {
        self.direction = direction
        self.split = split
        self.children = children
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(CmuxSplitDirection.self, forKey: .direction)
        split = try container.decodeIfPresent(Double.self, forKey: .split)
        children = try container.decode([CmuxLayoutNode].self, forKey: .children)
        if children.count != 2 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Split node requires exactly 2 children, got \(children.count)"
                )
            )
        }
    }

    /// The divider position clamped to `0.1...0.9`, defaulting to `0.5` when
    /// `split` is absent.
    public var clampedSplitPosition: Double {
        let value = split ?? 0.5
        return min(0.9, max(0.1, value))
    }

    /// The Bonsplit ``SplitOrientation`` the layout walk uses for this split.
    public var splitOrientation: SplitOrientation {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

/// The orientation of a `cmux.json` custom-layout split.
public enum CmuxSplitDirection: String, Codable, Sendable {
    /// A left/right split.
    case horizontal
    /// A top/bottom split.
    case vertical
}

/// A leaf pane in a `cmux.json` custom layout: a non-empty list of surfaces.
public struct CmuxPaneDefinition: Codable, Sendable {
    /// The surfaces declared in this pane, in declaration order. Guaranteed
    /// non-empty on decode.
    public var surfaces: [CmuxSurfaceDefinition]

    private enum CodingKeys: String, CodingKey {
        case surfaces
    }

    /// Creates a pane definition. The non-empty invariant is enforced on decode.
    public init(surfaces: [CmuxSurfaceDefinition]) {
        self.surfaces = surfaces
    }

    public init(from decoder: any Decoder) throws {
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

/// One surface declared inside a `cmux.json` custom-layout leaf pane.
public struct CmuxSurfaceDefinition: Codable, Sendable {
    /// The kind of surface to create.
    public var type: CmuxSurfaceType
    /// The custom tab title, if any.
    public var name: String?
    /// A startup command sent to the terminal once ready.
    public var command: String?
    /// The working directory for a terminal surface, relative to the layout's base cwd.
    public var cwd: String?
    /// Extra startup environment for a terminal surface.
    public var env: [String: String]?
    /// The URL for a browser surface, or the path for a project surface.
    public var url: String?
    /// Whether this surface should receive focus after the layout is applied.
    public var focus: Bool?

    /// Creates a surface definition.
    public init(
        type: CmuxSurfaceType,
        name: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        focus: Bool? = nil
    ) {
        self.type = type
        self.name = name
        self.command = command
        self.cwd = cwd
        self.env = env
        self.url = url
        self.focus = focus
    }
}

/// The kind of a `cmux.json` custom-layout surface.
public enum CmuxSurfaceType: String, Codable, Sendable {
    /// A terminal surface.
    case terminal
    /// A browser surface.
    case browser
    /// A project (file tree) surface.
    case project
}
