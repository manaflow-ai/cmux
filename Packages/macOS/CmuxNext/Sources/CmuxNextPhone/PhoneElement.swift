/// One element of a phone screen's accessibility tree: what agents read to
/// find what to tap (`cmux phone ui`).
public struct PhoneElement: Sendable, Hashable, Codable {
    /// The short role ("Button", "TextField", "StaticText").
    public var role: String
    /// The visible text or accessibility label.
    public var label: String
    /// The developer id (Android resource id, iOS accessibility identifier).
    public var identifier: String
    /// The element's current value (a text field's text), when it has one.
    public var value: String
    public var frame: PhoneRect
    public var children: [PhoneElement]

    public init(role: String, label: String = "", identifier: String = "", value: String = "",
                frame: PhoneRect, children: [PhoneElement] = []) {
        self.role = role
        self.label = label
        self.identifier = identifier
        self.value = value
        self.frame = frame
        self.children = children
    }

    /// This element and all below it, depth first.
    public var flattened: [PhoneElement] {
        [self] + children.flatMap(\.flattened)
    }
}
