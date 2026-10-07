public import AppKit

@MainActor
public final class BrowserOffscreenRenderPanel: NSPanel {
    /// Reports the panel as key without making it key. WebKit derives a
    /// page's active state (which gates mouse-move handling, so `:hover`) from
    /// `isKeyWindow`; WebKitTestRunner's window lies the same way. AppKit's
    /// real key window, first responder and keyboard focus are unaffected
    /// because the panel still refuses to become key.
    public var reportsKeyWindowForAutomation = false

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    public override var isKeyWindow: Bool { reportsKeyWindowForAutomation || super.isKeyWindow }
}
