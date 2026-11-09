/// One button of a ``HomeWidgetItem/buttons(_:)`` item.
public struct HomeWidgetButton: Hashable, Sendable, Codable {
    /// The scene node a click goes to.
    public var node: String
    public var title: String
    /// Drawn filled with the accent (the widget's main action).
    public var prominent: Bool
    /// A disabled button draws dimmed and takes no click.
    public var enabled: Bool

    public init(node: String, title: String, prominent: Bool = false, enabled: Bool = true) {
        self.node = node
        self.title = title
        self.prominent = prominent
        self.enabled = enabled
    }
}
