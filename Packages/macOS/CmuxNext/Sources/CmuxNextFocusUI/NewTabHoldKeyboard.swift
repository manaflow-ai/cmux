public import AppKit

/// What had the keyboard when a New Tab key hold opened. A hold that ends with no field ready gives its keys on to what
/// has the keyboard then, but never to this: when nothing took the keyboard since the opening, the person typed those
/// keys for the new page, and what would get them is the terminal he left. A typed line with Return ran there (a slow
/// page start in a pane that is not the focused one, a Cmd-N that failed; in the nightly from 2026-10-11).
@MainActor
public final class NewTabHoldKeyboard {
    private weak var owner: AnyObject?
    /// The hold ended with no field ready. Its owner sets this before the keys go on.
    public var endedUnready = false
    /// The keys that were not given on. A count: the text of a key is never kept or logged.
    public private(set) var dropped = 0

    public init(in window: NSWindow) {
        // A page in Chromium has the keys in its own window, a child of the shell.
        if let key = NSApp.keyWindow, key !== window, key.parent === window { owner = key } else { owner = Self.owner(of: window.firstResponder) }
    }

    /// A field editor stands for its field: one editor serves every field of a window.
    private static func owner(of responder: NSResponder?) -> AnyObject? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate { return field }
        return responder
    }

    /// Whether a held key that `responder` would get is dropped. It counts the key.
    public func drops(keyFor responder: NSResponder?) -> Bool {
        guard endedUnready, let owner, Self.owner(of: responder) === owner else { return false }
        dropped += 1
        return true
    }
}
