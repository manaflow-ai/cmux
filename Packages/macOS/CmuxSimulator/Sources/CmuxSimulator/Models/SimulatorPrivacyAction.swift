/// A privacy database operation supported by `simctl privacy`.
public enum SimulatorPrivacyAction: String, Codable, CaseIterable, Hashable, Sendable {
    /// Allow the selected service without prompting.
    case grant
    /// Deny the selected service.
    case revoke
    /// Restore the service to its prompt-on-use state.
    case reset
}
