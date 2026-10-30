import AppKit
import CmuxNextDesign

/// The palette's query field. An AX client reads a text field through its cell. Its placeholder
/// and caret share the field editor's line (`EditorAlignedTextField`), centered on the magnifier.
final class PaletteSearchField: EditorAlignedTextField {
    private weak var responderWindow: NSWindow?

    override class var cellClass: AnyClass? {
        get { PaletteSearchFieldCell.self }
        set {}
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if responderWindow !== window {
            if responderWindow?.initialFirstResponder === self {
                responderWindow?.initialFirstResponder = nil
            }
        }
        responderWindow = window
        guard let window else { return }
        window.initialFirstResponder = self
    }
}

/// AppKit's text field cell answers an AX client from its own attribute list, which leaves out the
/// label and identifier set on it: VoiceOver read an unnamed field once a query was typed
/// (cx-9ce.44). This cell answers both, and the placeholder it draws itself.
final class PaletteSearchFieldCell: EditorAlignedTextFieldCell {
    nonisolated override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [.description, .identifier, .placeholderValue]
    }

    nonisolated override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard [.description, .identifier, .placeholderValue].contains(attribute), Thread.isMainThread else {
            return super.accessibilityAttributeValue(attribute)
        }
        let value: String? = MainActor.assumeIsolated { // main-proof: checked Thread.isMainThread above
            switch attribute {
            case .description: accessibilityLabel()
            case .identifier: accessibilityIdentifier()
            default: accessibilityPlaceholderValue()
            }
        }
        return value
    }
}
