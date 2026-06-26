/// The selection behavior a browser omnibar address-bar focus request carries.
///
/// A focus request that owns explicit selection (Cmd+L) asks the omnibar to
/// select its whole contents on reassertion; a focus request driven by focus
/// restoration preserves whatever caret/selection the field editor already
/// placed. The omnibar focus coordinator reads ``shouldSelectAll`` when applying
/// a reasserted-focus effect (Chrome/Safari/Arc parity for the address bar).
///
/// The app target stored this as a free `enum` in `BrowserPanel.swift`; it is a
/// pure two-case value with no AppKit/`Workspace`/`BrowserPanel` reach, so it
/// belongs in this package next to the omnibar focus decisions that consume it.
public enum BrowserAddressBarFocusSelectionIntent: Equatable, Sendable {
    /// Keep the caret/selection the field editor placed; do not select all.
    case preserveFieldEditorSelection
    /// Select the field's entire contents on focus reassertion.
    case selectAll

    /// Whether reasserting focus with this intent should select the whole field.
    public var shouldSelectAll: Bool {
        self == .selectAll
    }
}
