struct BackendOnlyFocusRegistration {
    var content: BackendOnlyFocusSlotContent
    let requestFirstResponder: @MainActor () -> Bool
}
