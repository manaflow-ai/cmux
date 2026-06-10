internal import CmuxMobileSupport
import Foundation

/// One row of the connection doctor's checklist: which check ran, what it
/// concluded, and the localized text the user reads.
///
/// Items are pure values produced by ``ConnectionDoctorReport/make(results:)``
/// so the whole "probe results -> what the user reads" contract is
/// unit-testable with injected results, mirroring how
/// ``MobilePairingFailureCategory`` owns the pairing-failure mapping.
public struct ConnectionDoctorItem: Equatable, Sendable, Identifiable {
    /// The checks, declared in decision-tree order: network, then the tailnet
    /// (phone side, then the Mac's route), then the account, then the Mac app
    /// and its listener, then the persisted routes and the pairing link.
    /// ``ConnectionDoctorReport`` emits exactly one item per case, in
    /// `allCases` order, so the first failing row names the misconfiguration
    /// to fix first.
    public enum CheckID: String, CaseIterable, Sendable {
        /// Does this device have any network path at all?
        case network
        /// Did iOS block the dial on Local Network privacy grounds?
        case localNetwork
        /// Is Tailscale up on this phone (a tailnet self-address on a tunnel)?
        case tailnetPhone
        /// Does anything answer at the Mac's saved address (routable at all)?
        case macReachable
        /// Is this device signed in, and did the Mac accept the account?
        case account
        /// Is cmux running on the Mac with mobile connections listening?
        case listener
        /// Does this device hold a usable saved route, and is it still the
        /// address the registry says the Mac is at?
        case routes
        /// Was the last pairing QR/link still valid?
        case ticket
    }

    /// What a check concluded, with the one-line user-facing consequence.
    public enum Status: Equatable, Sendable {
        /// The check passed; `detail` optionally says what was observed.
        case pass(detail: String?)
        /// The check failed; `fix` is the localized one-line fix.
        case fail(fix: String)
        /// The probes could not determine this check either way; `note` says why.
        case unknown(note: String?)
        /// The check does not apply to the current setup; `note` says why.
        case skipped(note: String)
    }

    public let id: CheckID
    public let status: Status

    /// Creates a checklist row.
    /// - Parameters:
    ///   - id: Which check this row reports.
    ///   - status: What the check concluded.
    public init(id: CheckID, status: Status) {
        self.id = id
        self.status = status
    }

    /// Whether this row is a failure (the decision tree's "fix this" state).
    public var isFailure: Bool {
        if case .fail = status {
            return true
        }
        return false
    }

    /// The localized one-line fix when this row failed, else `nil`.
    public var fix: String? {
        if case let .fail(fix) = status {
            return fix
        }
        return nil
    }

    /// The localized checklist row title for this item's check.
    public var title: String {
        switch id {
        case .network:
            return L10n.string("mobile.doctor.check.network", defaultValue: "Internet connection")
        case .localNetwork:
            return L10n.string("mobile.doctor.check.localNetwork", defaultValue: "Local Network permission")
        case .tailnetPhone:
            return L10n.string("mobile.doctor.check.tailnetPhone", defaultValue: "Tailscale on this device")
        case .macReachable:
            return L10n.string("mobile.doctor.check.macReachable", defaultValue: "Mac reachable")
        case .account:
            return L10n.string("mobile.doctor.check.account", defaultValue: "Account")
        case .listener:
            return L10n.string("mobile.doctor.check.listener", defaultValue: "cmux running on the Mac")
        case .routes:
            return L10n.string("mobile.doctor.check.routes", defaultValue: "Saved address")
        case .ticket:
            return L10n.string("mobile.doctor.check.ticket", defaultValue: "Pairing link")
        }
    }
}
