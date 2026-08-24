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
    /// chrome sign-out button takes): on explicit staging it first warns
    /// that signing out returns this iPhone to its build lane (Production on
    /// every unpinned build).
    let interactive: @MainActor @Sendable () -> Void
    /// The root's direct sign-out chain for a just-deleted account: skips
    /// the staging warning (the account is gone; there is nothing left to
    /// keep a staging session for) but still chains the return to the lane
    /// when the device is on explicit staging.
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
/// SELECTION, extracted from `CMUXMobileRootView` so the per-environment
/// interception matrix is directly testable: ONLY explicit staging warns
/// before an interactive sign-out and chains the return to the build's lane;
/// a staging-LANE build keeps plain sign-outs (its home IS staging — a
/// dev-rig sign-out must stay a plain sign-out), production never warns and
/// never chains, and the delete-account direct path skips the warning but
/// still chains.
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
        /// Run the sign-out chain now. `returnsToLane` chains the backend
        /// switch back to the build's LANE after the sign-out completes
        /// (parking the just-signed-out coordinator is a safe no-op, and a
        /// lane target never gates or prompts; on an unpinned build the lane
        /// is production, so this is the identical return-to-production
        /// behavior).
        case perform(returnsToLane: Bool)
        /// Present the staging warning first; the confirmed sign-out then
        /// routes as `.perform(returnsToLane: true)` via
        /// ``confirmedStagingRoute``.
        case confirmStagingFirst
    }

    /// Route one request. Sign-out is per-environment and keyed on the
    /// SELECTION: only `.explicit(.staging)` intercepts or chains anything;
    /// every lane selection (a staging lane included) and explicit
    /// production keep the plain chain untouched.
    static func route(
        for request: Request,
        selection: CMUXBackendEnvironmentSelection
    ) -> Route {
        guard selection == .explicit(.staging) else {
            return .perform(returnsToLane: false)
        }
        switch request {
        case .interactive:
            return .confirmStagingFirst
        case .direct:
            return .perform(returnsToLane: true)
        }
    }

    /// The route a CONFIRMED staging warning resolves to: the real sign-out
    /// under the staging defaults (revocation hits staging), then the
    /// chained switch back to the build's lane restoring its parked session.
    static var confirmedStagingRoute: Route {
        .perform(returnsToLane: true)
    }
}
