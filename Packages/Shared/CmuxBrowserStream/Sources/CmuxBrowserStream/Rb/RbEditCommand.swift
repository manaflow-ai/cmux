/// An edit command the viewer's key bindings produced for a key
/// (Chromium names: `MoveWordLeft`, `Copy`).
public struct RbEditCommand: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String = "") {
        self.name = name
        self.value = value
    }
}
