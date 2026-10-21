import AppKit

/// The column layout's `NSBrowser`: hands unused keys to the pane.
final class FileBrowserControl: NSBrowser {
    /// Gets keys first; true when used.
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}
