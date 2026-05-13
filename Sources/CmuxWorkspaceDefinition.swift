import Foundation

struct CmuxWorkspaceDefinition: Codable, Sendable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: CmuxLayoutNode?
    var docks: CmuxWorkspaceDockConfiguration?

    init(
        name: String? = nil,
        cwd: String? = nil,
        color: String? = nil,
        layout: CmuxLayoutNode? = nil,
        docks: CmuxWorkspaceDockConfiguration? = nil
    ) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.layout = layout
        self.docks = docks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)
        docks = try container.decodeIfPresent(CmuxWorkspaceDockConfiguration.self, forKey: .docks)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            let defaults = decoder.userInfo[.cmuxWorkspaceColorDefaults] as? UserDefaults ?? .standard
            guard let normalized = WorkspaceTabColorSettings.resolvedColorHex(rawColor, defaults: defaults) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "Invalid color \"\(rawColor)\". Expected 6-digit hex format (#RRGGBB) or a workspace color name"
                )
            }
            color = normalized
        } else {
            color = nil
        }
    }
}

struct CmuxWorkspaceDockConfiguration: Codable, Sendable {
    var left: [CmuxWorkspaceDockDefinition]?
    var right: [CmuxWorkspaceDockDefinition]?
    var bottom: [CmuxWorkspaceDockDefinition]?

    init(
        left: [CmuxWorkspaceDockDefinition]? = nil,
        right: [CmuxWorkspaceDockDefinition]? = nil,
        bottom: [CmuxWorkspaceDockDefinition]? = nil
    ) {
        self.left = left
        self.right = right
        self.bottom = bottom
    }

    func definitions(for edge: WorkspaceDockEdge) -> [CmuxWorkspaceDockDefinition] {
        switch edge {
        case .left:
            return left ?? []
        case .right:
            return right ?? []
        case .bottom:
            return bottom ?? []
        }
    }

    func merging(primary: CmuxWorkspaceDockConfiguration) -> CmuxWorkspaceDockConfiguration {
        CmuxWorkspaceDockConfiguration(
            left: primary.left ?? left,
            right: primary.right ?? right,
            bottom: primary.bottom ?? bottom
        )
    }
}

struct CmuxWorkspaceDockDefinition: Codable, Sendable {
    var open: Bool?
    var width: Double?
    var height: Double?
    var layout: CmuxLayoutNode?

    private enum CodingKeys: String, CodingKey {
        case open
        case width
        case height
        case layout
    }

    init(
        open: Bool? = nil,
        width: Double? = nil,
        height: Double? = nil,
        layout: CmuxLayoutNode? = nil
    ) {
        self.open = open
        self.width = width
        self.height = height
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        open = try container.decodeIfPresent(Bool.self, forKey: .open)
        width = try Self.dimension(forKey: .width, in: container)
        height = try Self.dimension(forKey: .height, in: container)
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)
    }

    private static func dimension(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double? {
        guard container.contains(key) else { return nil }
        let value = try container.decode(Double.self, forKey: key)
        guard value.isFinite, value > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a positive finite number"
            )
        }
        return value
    }
}
