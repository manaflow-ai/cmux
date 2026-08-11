/// Method-name constants for the `gui.v1` RPC namespace.
// lint:allow namespace-type - The wire contract requires one method-name namespace.
public enum GuiWireMethod {
    /// Negotiates protocol and capability overlap.
    public static let hello = "gui.v1.hello"
    /// Pulls all current sessions.
    public static let sessions = "gui.v1.sessions"
    /// Pulls one current session.
    public static let session = "gui.v1.session"
    /// Pulls a bounded journal page.
    public static let entries = "gui.v1.entries"
    /// Submits an idempotent send ticket.
    public static let send = "gui.v1.send"
    /// Interrupts an agent session.
    public static let interrupt = "gui.v1.interrupt"
    /// Answers a pending ask.
    public static let answer = "gui.v1.answer"
    /// Pulls one session's capability report.
    public static let capabilities = "gui.v1.capabilities"
}
