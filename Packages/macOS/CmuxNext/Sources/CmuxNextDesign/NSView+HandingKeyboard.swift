public import AppKit

extension NSView {
    /// This view or a view inside it is its window's first responder (it has the keyboard).
    public var holdsKeyboard: Bool { (window?.firstResponder as? NSView)?.isDescendant(of: self) == true }

    /// The keyboard never stays in a view that stops showing: when this view or a view inside it is its window's first
    /// responder, the window takes the keyboard (the focus model then gives it to what shows now, as when a view leaves
    /// the window). Call it before the view hides. Hidden with the keyboard inside, AppKit walks the window's whole key
    /// view loop for a replacement (`-[NSView nextValidKeyView]`, `_NSComputeFirstKeyViewVisuallyInDirection`): 5.5 ms of
    /// New Terminal Tab's 19 ms key turn over a History tab (TERMINAL CREATE COST, cmux21). Returns false when a field
    /// editor refused to resign (it validates); the caller decides whether to end the edit.
    @discardableResult
    public func handKeyboardToWindow() -> Bool {
        guard holdsKeyboard, let window else { return true }
        return window.makeFirstResponder(nil)
    }
}
