/// A serialized accessibility element from the frontmost simulated app.
public struct SimulatorAccessibilityNode: Codable, Equatable, Identifiable, Sendable {
    /// A stable identifier when the runtime supplies one, otherwise a synthesized path.
    public let id: String
    /// The runtime-provided accessibility identifier, excluding synthesized paths.
    public let identifier: String?
    /// Whether the runtime identifier was clipped to the worker's field-size limit.
    public let isIdentifierTruncated: Bool
    /// The element role or type.
    public let role: String?
    /// The accessibility label.
    public let label: String?
    /// Whether the accessibility label was clipped to the worker's field-size limit.
    public let isLabelTruncated: Bool
    /// The accessibility value.
    public let value: String?
    /// Whether the accessibility value was clipped to the worker's field-size limit.
    public let isValueTruncated: Bool
    /// The runtime's localized description of the element role.
    public let roleDescription: String?
    /// The element frame in device points.
    public let frame: SimulatorRect?
    /// Whether the element accepts interaction.
    public let isEnabled: Bool?
    /// Whether the element owns accessibility focus, when exposed by the runtime.
    public let isFocused: Bool?
    /// Whether the element is selected, when exposed by the runtime.
    public let isSelected: Bool?
    /// Nested accessibility children.
    public let children: [SimulatorAccessibilityNode]

    /// Creates an accessibility element snapshot.
    public init(
        id: String,
        identifier: String? = nil,
        isIdentifierTruncated: Bool = false,
        role: String?,
        label: String?,
        isLabelTruncated: Bool = false,
        value: String?,
        isValueTruncated: Bool = false,
        roleDescription: String? = nil,
        frame: SimulatorRect?,
        isEnabled: Bool?,
        isFocused: Bool? = nil,
        isSelected: Bool? = nil,
        children: [SimulatorAccessibilityNode]
    ) {
        self.id = id
        self.identifier = identifier
        self.isIdentifierTruncated = isIdentifierTruncated
        self.role = role
        self.label = label
        self.isLabelTruncated = isLabelTruncated
        self.value = value
        self.isValueTruncated = isValueTruncated
        self.roleDescription = roleDescription
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case identifier
        case isIdentifierTruncated
        case role
        case label
        case isLabelTruncated
        case value
        case isValueTruncated
        case roleDescription
        case frame
        case isEnabled
        case isFocused
        case isSelected
        case children
    }

    /// Decodes a node while defaulting field-truncation flags for older workers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        isIdentifierTruncated = try container.decodeIfPresent(
            Bool.self,
            forKey: .isIdentifierTruncated
        ) ?? false
        role = try container.decodeIfPresent(String.self, forKey: .role)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        isLabelTruncated = try container.decodeIfPresent(
            Bool.self,
            forKey: .isLabelTruncated
        ) ?? false
        value = try container.decodeIfPresent(String.self, forKey: .value)
        isValueTruncated = try container.decodeIfPresent(
            Bool.self,
            forKey: .isValueTruncated
        ) ?? false
        roleDescription = try container.decodeIfPresent(
            String.self,
            forKey: .roleDescription
        )
        frame = try container.decodeIfPresent(SimulatorRect.self, forKey: .frame)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
        isFocused = try container.decodeIfPresent(Bool.self, forKey: .isFocused)
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected)
        children = try container.decode(
            [SimulatorAccessibilityNode].self,
            forKey: .children
        )
    }

    /// Encodes the node and emits only active field-truncation flags.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        if isIdentifierTruncated {
            try container.encode(true, forKey: .isIdentifierTruncated)
        }
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(label, forKey: .label)
        if isLabelTruncated {
            try container.encode(true, forKey: .isLabelTruncated)
        }
        try container.encodeIfPresent(value, forKey: .value)
        if isValueTruncated {
            try container.encode(true, forKey: .isValueTruncated)
        }
        try container.encodeIfPresent(roleDescription, forKey: .roleDescription)
        try container.encodeIfPresent(frame, forKey: .frame)
        try container.encodeIfPresent(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(isFocused, forKey: .isFocused)
        try container.encodeIfPresent(isSelected, forKey: .isSelected)
        try container.encode(children, forKey: .children)
    }
}

extension SimulatorAccessibilityNode {
    var subtreeNodeCount: Int {
        var count = 0
        var pending = [self]
        while let node = pending.popLast() {
            count += 1
            pending.append(contentsOf: node.children)
        }
        return count
    }
}
