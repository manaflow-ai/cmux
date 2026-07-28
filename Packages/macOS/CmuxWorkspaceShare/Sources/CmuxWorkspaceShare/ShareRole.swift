/// A participant's current host-authorized role.
public enum ShareRole: String, Codable, Sendable {
    /// May send input to a currently shared terminal pane.
    case editor

    /// May observe shared content but may not send input.
    case viewer
}
