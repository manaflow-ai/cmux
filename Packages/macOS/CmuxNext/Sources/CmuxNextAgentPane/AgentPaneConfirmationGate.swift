/// The one native mode confirmation that may be open in the whole app. Every pane's transport
/// shares ``shared``, so a page cannot open a second sheet through another pane or window: an ask
/// while one is open is refused (`transport.mode_not_confirmed`), not queued.
@MainActor public final class AgentPaneConfirmationGate {
    public static let shared = AgentPaneConfirmationGate()

    public private(set) var isOpen = false

    public init() {}

    /// Takes the gate; false when a confirmation is already open.
    func open() -> Bool {
        guard !isOpen else { return false }
        isOpen = true
        return true
    }

    func close() { isOpen = false }
}
