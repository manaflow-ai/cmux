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

/// A scope held without keeping its view or window alive, so a closed tab
/// can deallocate and end its dialogs (`CmuxDialogScopeLifetime`).
@MainActor
struct CmuxDialogWeakScope {
    enum Kind { case tab, window, app }

    let kind: Kind
    private(set) weak var view: NSView?
    private(set) weak var window: NSWindow?

    init(_ scope: CmuxDialogScope) {
        switch scope {
        case .tab(let view):
            kind = .tab
            self.view = view
        case .window(let window):
            kind = .window
            self.window = window
        case .app:
            kind = .app
        }
    }

    /// The scope while its view or window lives; nil once it is gone.
    var live: CmuxDialogScope? {
        switch kind {
        case .tab: view.map(CmuxDialogScope.tab)
        case .window: window.map(CmuxDialogScope.window)
        case .app: .app
        }
    }
}
