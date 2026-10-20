import Foundation

/// Where a "Send Feedback" submission is delivered.
///
/// The decision is pure: it depends only on the signed-in email, whether the
/// device currently has an active mobile-host connection to a paired Mac, and
/// the build type. The privileged path is intentionally NOT a debug-only path;
/// it must work on Release builds for the `@manaflow.ai` team, which is the
/// whole point of the feature.
public enum MobileFeedbackRoute: Equatable, Sendable {
    /// Deliver the rich diagnostic bundle straight to the paired Mac's agent
    /// sink (`dogfood.feedback.submit`), the same delivery the DEV dogfood
    /// affordance used. Reserved for privileged users; never offered to anyone
    /// else.
    case privilegedAgent
    /// Email the feedback inbox via the web `/api/feedback` route. The default
    /// for everyone who is not privileged.
    case email

    /// Pure routing decision for the Send Feedback feature.
    ///
    /// A submission goes direct-to-agent only when ALL of these hold:
    ///
    /// 1. The signed-in Stack user's email ends with `@manaflow.ai` (case- and
    ///    whitespace-insensitive), AND
    /// 2. The device is effectively on the tailnet — proxied by "has an active
    ///    mobile-host connection to a paired Mac", since that transport runs over
    ///    Tailscale, AND
    /// 3. The connected Mac advertises the `dogfood.v1` capability (the
    ///    `dogfood.feedback.submit` sink). Without this, a newer phone against an
    ///    older Mac would take the agent path and get `method_not_found`, so the
    ///    capability check makes it fall back to email under version skew.
    ///
    /// Build type does not change the route: the privileged path works on every
    /// build type (dev/beta/prod), so `@manaflow.ai` dogfooders on a Release build
    /// still send straight to the agent. Everyone else emails the inbox.
    ///
    /// - Parameters:
    ///   - email: The signed-in user's primary email, or `nil` when signed out or
    ///     when no email is set on the account.
    ///   - hasActiveMacConnection: `true` when an active mobile-host connection to a
    ///     paired Mac is established (the on-tailnet proxy).
    ///   - hostSupportsAgentSink: `true` when the connected Mac advertised the
    ///     `dogfood.v1` capability.
    /// - Returns: ``MobileFeedbackRoute/privilegedAgent`` when all privileged
    ///   conditions hold, otherwise ``MobileFeedbackRoute/email``.
    public static func resolve(
        email: String?,
        hasActiveMacConnection: Bool,
        hostSupportsAgentSink: Bool
    ) -> MobileFeedbackRoute {
        guard hasActiveMacConnection, hostSupportsAgentSink, isManaflowEmail(email) else {
            return .email
        }
        return .privilegedAgent
    }

    /// Whether an email belongs to the privileged `@manaflow.ai` domain.
    ///
    /// Trims surrounding whitespace and lowercases before matching, so a stored
    /// email with stray casing or padding still resolves correctly.
    ///
    /// - Parameter email: The candidate email, or `nil`.
    /// - Returns: `true` when the normalized email ends with `@manaflow.ai`.
    public static func isManaflowEmail(_ email: String?) -> Bool {
        guard let email else { return false }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix("@manaflow.ai")
    }
}
