import Foundation

/// The requirements-checklist status mapping for the pairing window: how each
/// checklist row derives its badge state from the model's render ``MobilePairingModel/State``.
extension MobilePairingModel {
    /// Status of one requirements-checklist row, derived from ``State``.
    /// Drives the shared status badge in ``MobilePairingView``: `needsAction`
    /// is the red "fix this" state, `complete` the green done state, and
    /// `pending` stays neutral while the step can't be evaluated yet.
    enum RequirementStatus: Equatable {
        /// The requirement is satisfied.
        case complete
        /// The requirement blocks pairing and the user must act.
        case needsAction
        /// Not yet known: still resolving, or gated behind an earlier step.
        case pending
    }

    /// Status of the "Signed in to cmux" checklist row.
    var signInRequirement: RequirementStatus {
        Self.signInRequirementStatus(for: state, signedIn: isSignedIn)
    }

    /// Status of the Tailscale checklist row.
    var tailscaleRequirement: RequirementStatus {
        Self.tailscaleRequirementStatus(for: state)
    }

    /// Maps the render state onto the sign-in checklist row. A confirmed
    /// account always completes the step. Otherwise only an explicit
    /// `.signedOut` turns the row red; resolving states (and a failure before
    /// auth ever resolved) stay neutral. Pure, so the mapping is unit tested
    /// without a live coordinator.
    static func signInRequirementStatus(for state: State, signedIn: Bool) -> RequirementStatus {
        if signedIn { return .complete }
        switch state {
        case .signedOut:
            return .needsAction
        case .loading, .preparing, .ready, .connected, .needsTailscale, .failed:
            return .pending
        }
    }

    /// Maps the render state onto the Tailscale checklist row. Red only once
    /// we know the phone has no route (`.needsTailscale`, or a ticket minted
    /// without a Tailscale route); neutral while loading, signed out, or
    /// failed, where reachability hasn't been evaluated. Pure for unit tests.
    static func tailscaleRequirementStatus(for state: State) -> RequirementStatus {
        switch state {
        case .needsTailscale:
            return .needsAction
        case let .ready(ready), let .connected(ready):
            return ready.reachableViaTailscale ? .complete : .needsAction
        case .loading, .signedOut, .preparing, .failed:
            return .pending
        }
    }
}
