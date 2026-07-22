/// A persisted response to a runtime optional-permission request.
public enum BrowserWebExtensionPermissionDecision: String, Codable, Equatable, Sendable {
    /// Grant the requested optional access and remember it for this profile.
    case grant

    /// Deny the requested optional access and remember the denial.
    case deny
}
