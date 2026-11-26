/// A single command captured from a `Button`'s action closure.
///
/// The interpreter records the call shape; a host runtime executes it. The
/// `cmux` case maps onto cmux's socket command dispatcher (`method` + string
/// arguments), giving interpreted buttons the breadth of the cmux CLI.
public enum ActionCommand: Codable, Sendable, Equatable {
    /// A cmux command: a dispatcher method plus named string params, e.g.
    /// `cmux("workspace.select", workspace_id: w.id)` →
    /// `.cmux("workspace.select", ["workspace_id": "<uuid>"])`. Maps directly
    /// onto the socket command protocol (`{"method","params"}`).
    case cmux(method: String, params: [String: String])
    case log(String)
    /// Opens a URL (host runs it, e.g. via the workspace opener).
    case openURL(String)
}
