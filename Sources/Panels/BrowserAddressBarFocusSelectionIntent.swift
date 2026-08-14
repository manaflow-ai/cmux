enum BrowserAddressBarFocusSelectionIntent: Equatable {
    case preserveFieldEditorSelection
    case selectAll

    var shouldSelectAll: Bool {
        self == .selectAll
    }
}
