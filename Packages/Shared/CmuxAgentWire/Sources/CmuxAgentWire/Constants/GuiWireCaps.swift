/// Open capability-string constants advertised during GUI negotiation.
// lint:allow namespace-type - The wire contract requires one capability namespace.
public enum GuiWireCaps {
    /// Bounded journal paging is supported.
    public static let entriesPaging = "entries-paging"
    /// Idempotent send tickets are supported.
    public static let sendTickets = "send-tickets"
    /// Structured pending-ask answers are supported.
    public static let answers = "answers"
    /// Machine-readable session capability reports are supported.
    public static let capabilitiesReport = "capabilities-report"
}
