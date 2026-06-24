/// What the address bar should do with the field editor's selection at the
/// instant it gains first responder, expressed as a pure intent the field
/// editor resolves to a boolean.
///
/// When focus arrives the omnibar either selects the entire URL (so the user
/// can immediately type a replacement) or leaves the field editor's existing
/// selection untouched (so a caller that already placed a caret or range keeps
/// it). The intent carries no side effects: a caller stages it as pending
/// state, and the AppKit field editor reads `shouldSelectAll` to decide, while
/// a test exercises the predicate without an `NSTextField`.
public enum BrowserAddressBarFocusSelectionIntent: Sendable, Equatable {
    /// Keep whatever selection the field editor already holds.
    case preserveFieldEditorSelection

    /// Select the field's entire contents on focus gain.
    case selectAll

    /// `true` only for `.selectAll`.
    public var shouldSelectAll: Bool {
        self == .selectAll
    }
}
