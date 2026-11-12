/// What one chat widget shows now: a flat list of drawable items the Home transcript draws
/// natively in an incoming bubble (plans/cmux-next/chat-widgets-DESIGN.md section 4).
///
/// A host (``HomeWidgetHosting``) makes it from the scene an app's `cmux.chat.widget/1`
/// export returns. It is a value, so the transcript can measure and draw it off the main
/// thread, and every change is a new snapshot (the row's version changes with it).
///
/// ```swift
/// let card = HomeWidgetSnapshot(items: [
///     .text("Model picker finds any model", style: .headline),
///     .row(node: "r1", title: "macOS tests", subtitle: "passed", symbol: "checkmark.circle", tint: .success),
///     .buttons([HomeWidgetButton(node: "more", title: "Show more")]),
/// ])
/// ```
public struct HomeWidgetSnapshot: Hashable, Sendable, Codable {
    /// A semantic color the transcript resolves with its own palette (light and dark).
    public enum Tint: String, Hashable, Sendable, Codable {
        case primary, secondary, accent, success, warning, danger
    }

    /// A text item's size and weight.
    public enum TextStyle: String, Hashable, Sendable, Codable {
        case headline, body, caption
    }

    /// The items, top to bottom.
    public var items: [HomeWidgetItem]

    /// - Parameter items: the items, top to bottom; the transcript draws at most ``maxItems``.
    public init(items: [HomeWidgetItem]) {
        self.items = items
    }

    /// The most items a widget draws: longer lists are the app's to page.
    public static let maxItems = 14
}
