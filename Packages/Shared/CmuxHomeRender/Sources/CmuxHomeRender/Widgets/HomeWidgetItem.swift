/// One drawable item of a ``HomeWidgetSnapshot``.
public enum HomeWidgetItem: Hashable, Sendable, Codable {
    /// Wrapped text.
    case text(String, style: HomeWidgetSnapshot.TextStyle = .body, tint: HomeWidgetSnapshot.Tint = .primary)
    /// A list row: a symbol, a title and an optional subtitle and badge. `node` is the scene node a
    /// click goes to (nil: not clickable).
    case row(node: String?, title: String, subtitle: String? = nil, symbol: String? = nil,
             tint: HomeWidgetSnapshot.Tint = .secondary, badge: String? = nil)
    /// A row of buttons (one button, or Previous and Next).
    case buttons([HomeWidgetButton])
    /// A small status pill.
    case badge(String, tint: HomeWidgetSnapshot.Tint)
    /// A hairline between items.
    case divider
    /// A centered message for an empty or failed list.
    case empty(title: String, message: String? = nil, symbol: String? = nil)
}
