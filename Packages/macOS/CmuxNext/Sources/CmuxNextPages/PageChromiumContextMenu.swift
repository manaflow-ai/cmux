public import Foundation

/// A right-click in a Chromium page (Chromium's own menu does not show): what the host needs to
/// build the page's native menu as the WebKit page does (``PageWebView/contextMenuEditor``).
public nonisolated struct PageChromiumContextMenu: Sendable, Equatable {
    /// Where the click was, in the page view (points, top-left origin).
    public var location: CGPoint
    /// The page's selected text (empty for none).
    public var selection: String
    /// Whether the click was in an editable field.
    public var isEditable: Bool
    /// Tells Chromium the menu closed; the host calls it once, after its menu (or none) is done.
    public var finish: @MainActor @Sendable () -> Void

    /// - Parameters:
    ///   - location: Where the click was, in the page view (top-left origin).
    ///   - selection: The selected text.
    ///   - isEditable: Whether the click was in an editable field.
    ///   - finish: Tells Chromium the menu closed.
    public init(location: CGPoint, selection: String, isEditable: Bool, finish: @escaping @MainActor @Sendable () -> Void) {
        self.location = location
        self.selection = selection
        self.isEditable = isEditable
        self.finish = finish
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.location == rhs.location && lhs.selection == rhs.selection && lhs.isEditable == rhs.isEditable
    }
}
