public import AppKit

/// A key held behind a page's queued text, with the window it was typed in (``TypeAheadTail``).
public struct HeldTypeAheadKey {
    /// The key-down as typed; it is sent again once the text landed.
    public let event: NSEvent
    /// The window it was typed in; a key whose window closed is not run.
    public weak var window: NSWindow?

    public init(event: NSEvent, window: NSWindow?) {
        (self.event, self.window) = (event, window)
    }
}
