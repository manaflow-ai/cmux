/// The one native mode confirmation that may be open in the whole app. The App's agent tab store
/// holds one gate and gives it to every pane's transport (``AgentPaneTransport/confirmationGate``),
/// so a page cannot open a second sheet through another pane or window: an ask while one is open
/// is refused (`transport.mode_not_confirmed`), not queued. A transport made without one (a test's)
/// has its own.
@MainActor public final class AgentPaneConfirmationGate {
    /// A confirmation (mode or Enable harness) is open now.
    public private(set) var isOpen = false

    /// A closed gate.
    public init() {}

    /// Takes the gate; false when a confirmation is already open.
    func open() -> Bool {
        guard !isOpen else { return false }
        isOpen = true
        return true
    }

    func close() { isOpen = false }
}
