/// Resolves page-driven and manual requests for the hidden keyboard proxy.
struct BrowserStreamKeyboardPolicy: Equatable, Sendable {
    /// Whether the Mac page reports an editable element focused.
    private(set) var editableFocused = false
    /// Whether the user manually requested the keyboard.
    private(set) var manuallyRequested = false
    /// Whether the user hid the keyboard while page focus remains editable.
    private(set) var manuallyDismissed = false

    /// Creates a keyboard policy with no focus request.
    init() {}

    /// Whether the hidden input proxy should hold first responder.
    var shouldFocusInput: Bool { !manuallyDismissed && (editableFocused || manuallyRequested) }

    /// Applies the page's focused-element state.
    /// - Parameter focused: Whether the page focus accepts text.
    mutating func setEditableFocused(_ focused: Bool) {
        guard focused != editableFocused else { return }
        editableFocused = focused
        manuallyDismissed = false
        if focused { manuallyRequested = false }
    }

    /// Toggles the manual keyboard request used when a page swallows focus events.
    mutating func toggleManualRequest() {
        if shouldFocusInput {
            manuallyRequested = false
            manuallyDismissed = true
        } else {
            manuallyRequested = true
            manuallyDismissed = false
        }
    }

    /// Clears every keyboard focus reason.
    mutating func dismiss() {
        editableFocused = false
        manuallyRequested = false
        manuallyDismissed = false
    }
}
