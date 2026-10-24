import AppKit

/// The palette's query field. An AX client reads a text field through its cell.
final class PaletteSearchField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PaletteSearchFieldCell.self }
        set {}
    }

    // The panel is a detached child window: AppKit can attach this view before the panel becomes
    // key. Registering the initial responder lets the window-server hand the keys to the query
    // field during that transition instead of leaving the terminal as the responder.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow, window.initialFirstResponder === self {
            window.initialFirstResponder = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
    }
}

/// AppKit's text field cell answers an AX client from its own attribute list, which leaves out the
/// label and identifier set on it: VoiceOver read an unnamed field once a query was typed
/// (cx-9ce.44). This cell answers both.
final class PaletteSearchFieldCell: NSTextFieldCell {
    nonisolated override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [.description, .identifier]
    }

    nonisolated override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard attribute == .description || attribute == .identifier, Thread.isMainThread else {
            return super.accessibilityAttributeValue(attribute)
        }
        let value: String? = MainActor.assumeIsolated { // main-proof: checked Thread.isMainThread above
            attribute == .description ? accessibilityLabel() : accessibilityIdentifier()
        }
        return value
    }
}
