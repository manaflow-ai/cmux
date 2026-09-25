public import AppKit
internal import CmuxFoundation

public extension NSResponder {
    /// Whether this responder should be treated as a terminal-surface or browser
    /// focus-stealer while the command palette is visible.
    ///
    /// A responder is focus-stealing when it (or, for views, an ancestor in the
    /// view hierarchy) conforms to the `FocusStealingResponder` marker. Field-editor
    /// `NSTextView`s are classified by their hosting view hierarchy rather than by
    /// reading `NSTextView.delegate`, which AppKit exposes as unsafe-unretained.
    var isCommandPaletteFocusStealingTerminalOrBrowser: Bool {
        if self is any FocusStealingResponder {
            return true
        }

        if let textView = self as? NSTextView, !textView.isFieldEditor {
            return textView.commandPaletteFocusStealingSurfaceInViewHierarchy
        }

        if let view = self as? NSView {
            return view.commandPaletteFocusStealingSurfaceInViewHierarchy
        }

        return false
    }
}
