import AppKit

/// The palette's query field. An AX client reads a text field through its cell.
final class PaletteSearchField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PaletteSearchFieldCell.self }
        set {}
    }
}

/// AppKit's text field cell answers an AX client from its own attribute list, which leaves out the
/// label and identifier set on it: VoiceOver read an unnamed field once a query was typed
/// (cx-9ce.44). This cell answers both.
final class PaletteSearchFieldCell: NSTextFieldCell {
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [.description, .identifier]
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case .description: return accessibilityLabel()
        case .identifier: return accessibilityIdentifier()
        default: return super.accessibilityAttributeValue(attribute)
        }
    }
}
