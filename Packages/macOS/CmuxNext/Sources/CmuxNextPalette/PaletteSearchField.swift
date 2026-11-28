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
