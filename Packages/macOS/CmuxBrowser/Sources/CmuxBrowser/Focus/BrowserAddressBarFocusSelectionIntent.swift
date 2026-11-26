public enum BrowserAddressBarFocusSelectionIntent: Equatable {
    case preserveFieldEditorSelection
    case selectAll

    public var shouldSelectAll: Bool {
        self == .selectAll
    }
}
