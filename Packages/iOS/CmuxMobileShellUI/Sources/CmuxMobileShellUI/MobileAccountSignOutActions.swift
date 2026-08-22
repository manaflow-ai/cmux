// No os() gate: this value threads through the cross-platform workspace
// shell chain (host → shell view → list) on the way to the iOS-only
// Settings surfaces.
import CMUXAuthCore

/// The two root-owned sign-out paths Settings' account section can take.
///
/// A REQUIRED value (never an optional closure): the account section's
/// delete-account flow previously fell back to a raw `authManager.signOut()`
/// when its optional closure was nil, silently skipping the root's teardown
/// chain (`signOutHook`, shell reset) and the per-environment interception.
/// Carrying both paths in one non-optional value closes that bypass — every
/// host explicitly chooses what each path does.
struct MobileAccountSignOutActions {
    /// The root's confirming sign-out choke point (the same path every
    /// chrome sign-out button takes): on staging it first warns that signing
    /// out returns this iPhone to Production.
    let interactive: @MainActor @Sendable () -> Void
    /// The root's direct sign-out chain for a just-deleted account: skips
    /// the staging warning (the account is gone; there is nothing left to
    /// keep a staging session for) but still chains the return to
    /// Production when the device is on staging.
    let direct: @MainActor @Sendable () -> Void

    init(
        interactive: @escaping @MainActor @Sendable () -> Void,
        direct: @escaping @MainActor @Sendable () -> Void
    ) {
        self.interactive = interactive
        self.direct = direct
    }

    /// Explicit inert value for previews and package test hosts, which have
    /// no composition root to sign out of. Both paths intentionally do
    /// NOTHING — unlike the removed nil-closure fallback, no path silently
    /// reaches for the coordinator behind the root's back.
    static let unwired = MobileAccountSignOutActions(interactive: {}, direct: {})
}

/// Pure routing for a sign-out request against the active backend
/// environment, extracted from `CMUXMobileRootView` so the per-environment
/// interception matrix is directly testable: staging warns before an
/// interactive sign-out and chains the return to Production, production
/// never warns and never chains, and the delete-account direct path skips
/// the warning but still chains.
enum MobileSignOutInterception {
    /// How the sign-out was requested.
    enum Request: Equatable {
        /// A user-facing sign-out control (Settings button, chrome menu,
        /// recovery banner).
        case interactive
        /// The post-account-deletion path: the account no longer exists, so
        /// warning about losing its staging session would be meaningless.
        case direct
    }

    /// What the root does with the request.
    enum Route: Equatable {
        /// Run the sign-out chain now. `returnsToProduction` chains the
        /// backend switch back to Production after the sign-out completes
        /// (parking the just-signed-out coordinator is a safe no-op, and the
        /// production restore never gates or prompts).
        case perform(returnsToProduction: Bool)
        /// Present the staging warning first; the confirmed sign-out then
        /// routes as `.perform(returnsToProduction: true)` via
        /// ``confirmedStagingRoute``.
        case confirmStagingFirst
    }

    /// Route one request. Sign-out is per-environment: only an ACTIVE
    /// staging environment intercepts or chains anything; production keeps
    /// the plain chain untouched.
    static func route(
        for request: Request,
        active: CMUXBackendEnvironmentOverride
    ) -> Route {
        guard active == .staging else {
            return .perform(returnsToProduction: false)
        }
        switch request {
        case .interactive:
            return .confirmStagingFirst
        case .direct:
            return .perform(returnsToProduction: true)
        }
    }

    /// The route a CONFIRMED staging warning resolves to: the real sign-out
    /// under the staging defaults (revocation hits staging), then the
    /// chained switch back to Production restoring the parked production
    /// session.
    static var confirmedStagingRoute: Route {
        .perform(returnsToProduction: true)
    }
}
