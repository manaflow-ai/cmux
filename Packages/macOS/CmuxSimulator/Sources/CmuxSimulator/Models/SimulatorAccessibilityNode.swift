/// A serialized accessibility element from the frontmost simulated app.
public struct SimulatorAccessibilityNode: Codable, Equatable, Identifiable, Sendable {
    /// A stable identifier when the runtime supplies one, otherwise a synthesized path.
    public let id: String
    /// The element role or type.
    public let role: String?
    /// The accessibility label.
    public let label: String?
    /// The accessibility value.
    public let value: String?
    /// The runtime's localized description of the element role.
    public let roleDescription: String?
    /// The element frame in device points.
    public let frame: SimulatorRect?
    /// Whether the element accepts interaction.
    public let isEnabled: Bool?
    /// Nested accessibility children.
    public let children: [SimulatorAccessibilityNode]

    /// Creates an accessibility element snapshot.
    public init(
        id: String,
        role: String?,
        label: String?,
        value: String?,
        roleDescription: String? = nil,
        frame: SimulatorRect?,
        isEnabled: Bool?,
        children: [SimulatorAccessibilityNode]
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.roleDescription = roleDescription
        self.frame = frame
        self.isEnabled = isEnabled
        self.children = children
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
