import AppKit

/// The floating sidebar card's window.
///
/// Not key by default: the parent keeps keyboard focus, so keystrokes keep
/// flowing to the terminal while the card is up, and hovering or clicking a
/// row cannot steal the window's key state out from under the peek gesture.
///
/// A text editor inside the card (inline rename, a checklist field) is the
/// exception. Typing has to reach it, so the panel becomes key for exactly
/// as long as an editor owns its first responder, then hands key back to
/// the parent window, whose own first responder (the terminal) never moved.
final class SidebarPeekPanelWindow: NSPanel {
    /// Called when the panel takes or gives up keyboard focus for an editor,
    /// so the owner can hold the peek open while the user types.
    var onKeyboardFocusChange: ((Bool) -> Void)?

    /// Whether an editor may take the keyboard at all: only while the card
    /// is showing. The hidden card's list stays live and can arm a field on
    /// its own (a checklist add request), which must not pull typing into
    /// an invisible window.
    var allowsKeyboardEditors = false {
        didSet {
            guard !allowsKeyboardEditors, hostsKeyboardEditor else { return }
            endKeyboardEditing()
        }
    }

    /// True while an editor inside the card owns the first responder.
    private(set) var hostsKeyboardEditor = false {
        didSet {
            guard oldValue != hostsKeyboardEditor else { return }
            onKeyboardFocusChange?(hostsKeyboardEditor)
        }
    }

    override var canBecomeKey: Bool { hostsKeyboardEditor }
    override var canBecomeMain: Bool { false }

    /// Whether `responder` takes typed text: a field editor or an editable
    /// text control. Row views, the table, and buttons do not.
    static func takesKeyboardInput(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        if let field = responder as? NSTextField {
            return field.isEditable
        }
        return false
    }

    /// An editor still attached to this panel owns the first responder. A
    /// field editor left behind by a removed field has no window and does
    /// not count.
    private var editorOwnsFirstResponder: Bool {
        guard let responder = firstResponder, Self.takesKeyboardInput(responder) else { return false }
        return (responder as? NSView)?.window === self
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let wantsKeyboard = Self.takesKeyboardInput(responder)
        if wantsKeyboard, !hostsKeyboardEditor, allowsKeyboardEditors {
            // Key first, then the responder: the field editor attaches to a
            // key window, and the selection it makes on attach is what the
            // user's first keystroke replaces.
            hostsKeyboardEditor = true
            makeKey()
        }
        let accepted = super.makeFirstResponder(responder)
        if accepted, !wantsKeyboard {
            relinquishKeyboardFocus()
        } else if !accepted, wantsKeyboard, !editorOwnsFirstResponder {
            relinquishKeyboardFocus()
        }
        return accepted
    }

    /// Runs on every pass through the event loop. An editor removed from the
    /// hierarchy (a committed rename tears its field down) does not always
    /// go through `makeFirstResponder`, so this is where the panel notices
    /// the editor is gone and gives key back.
    override func update() {
        super.update()
        if hostsKeyboardEditor, !editorOwnsFirstResponder {
            relinquishKeyboardFocus()
        }
    }

    override func resignKey() {
        super.resignKey()
        guard hostsKeyboardEditor else { return }
        // The user clicked elsewhere (usually the terminal). End the edit
        // the way a docked row does when focus leaves it: the editor's end
        // editing commits, and the rename field tears itself down.
        hostsKeyboardEditor = false
        _ = super.makeFirstResponder(nil)
    }

    /// Ends the edit (the editor's end editing commits, like clicking away)
    /// and returns key to the parent window.
    func endKeyboardEditing() {
        relinquishKeyboardFocus()
        _ = super.makeFirstResponder(nil)
    }

    /// Drops editor focus and returns key to the parent window.
    func relinquishKeyboardFocus() {
        guard hostsKeyboardEditor else { return }
        hostsKeyboardEditor = false
        if isKeyWindow, let parent, parent.isVisible {
            parent.makeKey()
        }
    }
}
