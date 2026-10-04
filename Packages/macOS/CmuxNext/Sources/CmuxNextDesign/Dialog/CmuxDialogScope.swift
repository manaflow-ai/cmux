public import AppKit

/// Where a dialog shows and what it blocks.
public enum CmuxDialogScope {
    /// Blocks only `view` (a tab's content); the rest of the window works.
    case tab(NSView)
    /// Blocks the whole window.
    case window(NSWindow)
    /// No window to attach to (quit with every window closed).
    case app

    public var kind: String {
        switch self {
        case .tab: "tab"
        case .window: "window"
        case .app: "app"
        }
    }

    /// Dialogs in one scope show one at a time, in order.
    var key: ObjectIdentifier? {
        switch self {
        case .tab(let view): ObjectIdentifier(view)
        case .window(let window): ObjectIdentifier(window)
        case .app: nil
        }
    }

    var window: NSWindow? {
        switch self {
        case .tab(let view): view.window
        case .window(let window): window
        case .app: nil
        }
    }
}
