import Foundation

/// Decides who may see the backend environment picker in Settings.
///
/// UX gating only, not a security boundary: the staging deployment's own auth
/// is what protects staging, and its URL is public. The gate exists so the
/// picker never confuses testers outside the team. Callers additionally show
/// the picker in DEBUG builds and whenever a non-production override is
/// already active, so switching back to production is always possible.
public enum CMUXBackendEnvironmentSwitchGate {
    /// The email domain whose verified members may switch environments.
    public static let allowedEmailDomainSuffix = "@manaflow.ai"

    /// Whether the signed-in user unlocks the picker: a verified primary
    /// email on the allowed domain. Unverified emails never qualify, since a
    /// user can set an arbitrary unverified address on their own account.
    public static func allows(_ user: CMUXAuthUser?) -> Bool {
        guard let user, user.primaryEmailVerified, let email = user.primaryEmail else {
            return false
        }
        return email.lowercased().hasSuffix(allowedEmailDomainSuffix)
    }
}
