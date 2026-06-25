public import AppKit

public extension NSView {
    /// Returns the first `NSButton` in this view's subtree (depth-first,
    /// self-first) whose `title` equals `title`, or `nil` if none matches.
    ///
    /// Used by the close-confirmation shortcut router to locate the confirm
    /// button on a stock `NSAlert` panel so a forwarded key equivalent
    /// (Cmd+D in XCUITest) can click it. The walk is a pure recursive
    /// descendant search with no presenter state.
    func firstDescendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }
        for subview in subviews {
            if let found = subview.firstDescendantButton(titled: title) {
                return found
            }
        }
        return nil
    }

    /// Returns whether any `NSTextField` in this view's subtree (depth-first,
    /// self-first) has a `stringValue` equal to `text`.
    ///
    /// Used by the close-confirmation shortcut router to detect a visible
    /// confirmation alert panel by matching its title label, so the router can
    /// avoid stealing shortcuts while the confirmation is up. The walk is a pure
    /// recursive descendant search with no presenter state.
    func containsStaticText(_ text: String) -> Bool {
        if let field = self as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in subviews {
            if subview.containsStaticText(text) {
                return true
            }
        }
        return false
    }
}
