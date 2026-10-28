public import AppKit

extension NSWindow {
    /// Closes the window as its close button does, in the caller's turn: the delegate's
    /// `windowShouldClose(_:)` decides, then `close()`. It never flashes the close button.
    ///
    /// `performClose(_:)` "simulates the user clicking the close button by momentarily highlighting the
    /// button": AppKit's `-[NSButtonCell performClick:]` runs a nested event-tracking run loop to draw the
    /// highlight, about 100 ms on the key turn of a keyboard or scripted close (v2.2.4-opt: Close Window
    /// took 102 ms, outcome `nested`). Chrome closes a window from a key or a script without any button
    /// highlight (`BrowserView::Close`, `views::Widget::Close`). A click on the button itself keeps AppKit's
    /// own path; this is for closes that are not that click.
    ///
    /// ```swift
    /// window.closeWithoutButtonFlash()   // Ctrl-Cmd-W, the menu, `closeWindow` from a script
    /// ```
    ///
    /// - Returns: Whether the window closed now: false when it cannot close (no close button in its
    ///   style) or its delegate kept it open (a confirmation, or a close that ends after a fade).
    @discardableResult
    public func closeWithoutButtonFlash() -> Bool {
        guard styleMask.contains(.closable) else { return false }
        if delegate?.windowShouldClose?(self) == false { return false }
        close()
        return true
    }
}
