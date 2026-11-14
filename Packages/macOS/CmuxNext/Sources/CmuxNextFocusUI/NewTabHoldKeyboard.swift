public import AppKit

/// What had the keyboard when a New Tab key hold opened. A hold that ends with no field ready gives its keys on to what
/// has the keyboard then, but never to this: when nothing took the keyboard since the opening, the person typed those
/// keys for the new page, and what would get them is the terminal he left. A typed line with Return ran there (a slow
/// page start in a pane that is not the focused one, a Cmd-N that failed; in the nightly from 2026-10-11).
@MainActor
public final class NewTabHoldKeyboard {
    /// What a responder stands for when its own object can be made again while the hold lives; nil: itself.
    public typealias StandIn = @MainActor (NSResponder) -> AnyObject?

    /// The opening was the person's (a key, a click, a menu), or it replaced a hold of such an opening.
    public let persons: Bool
    private weak var owner: AnyObject?
    /// The window whose keys the hold has: its owner is a view (or a page window) of this window.
    private weak var window: NSWindow?
    private let standIn: StandIn
    /// The hold ended with no field ready. Its owner sets this before the keys go on.
    public var endedUnready = false
    /// The keys that were not given on. A count: the text of a key is never kept or logged.
    public private(set) var dropped = 0

    /// `standIn`: a terminal makes its surface view again at a replay, so that view stands for the terminal's host view.
    /// `replaced`: the hold that this opening replaces in the window, if one lives.
    public init(in window: NSWindow, persons: Bool = true, replacing replaced: NewTabHoldKeyboard? = nil, standIn: @escaping StandIn = { _ in nil }) {
        self.standIn = standIn
        self.window = window
        self.persons = persons || replaced?.persons == true
        // An opening that is not the person's (a script, the CLI, an agent): the held keys are what the person types
        // in the view they are in. No owner is recorded, so no key is dropped: that view gets them at an unready end.
        guard self.persons else { return }
        // A script's opening that replaces a hold of the person is not a moment that the person chose: the owner
        // stays what had the keyboard at the person's opening (a page that took the keyboard since then gets its keys).
        // Only for a hold of this window: a New Window hold is found from every window, and its owner is in the window
        // of its opening. The keys of this hold run in THIS window, so what has the keyboard here is the owner (below):
        // a line that the person typed in the other window runs in no view of this one.
        if !persons, let replaced, replaced.window === window {
            owner = replaced.owner
            return
        }
        // A page in Chromium has the keys in its own window, a child of the shell.
        if let key = NSApp.keyWindow, key !== window, key.parent === window { owner = key } else { owner = whatStands(for: window.firstResponder) }
    }

    /// A field editor stands for its field: one editor serves every field of a window.
    private func whatStands(for responder: NSResponder?) -> AnyObject? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate { return field }
        if let responder, let stand = standIn(responder) { return stand }
        return responder
    }

    /// Whether a held key that `responder` would get is dropped. It counts the key.
    public func drops(keyFor responder: NSResponder?) -> Bool {
        guard endedUnready, let owner, whatStands(for: responder) === owner else { return false }
        dropped += 1
        return true
    }
}
