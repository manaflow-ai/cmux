public import AppKit

@MainActor
public final class BrowserOffscreenRenderPanel: NSPanel {
    /// Reports the panel as key without making it key. WebKit derives a
    /// page's active state (which gates mouse-move handling, so `:hover`) from
    /// `isKeyWindow`; WebKitTestRunner's window lies the same way. AppKit's
    /// real key window, first responder and keyboard focus are unaffected
    /// because the panel still refuses to become key.
    // WebKit can query this flag from a framework callback that does not carry
    // Swift's MainActor executor token. The panel remains AppKit-main-thread
    // owned; the unsafe annotation only makes that callback boundary explicit.
    public nonisolated(unsafe) var reportsKeyWindowForAutomation = false

    public nonisolated override var canBecomeKey: Bool { false }
    public nonisolated override var canBecomeMain: Bool { false }
    public nonisolated override var isKeyWindow: Bool { reportsKeyWindowForAutomation || super.isKeyWindow }
}
