import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Display-only derivations for the pairing checklist: the localized title and
/// one-line "what this gate checks" detail for each gate, and the icon / tint /
/// accessibility wording for each gate status. Kept out of the model so the
/// model stays UI-agnostic and these strings live next to the view that shows
/// them (https://github.com/manaflow-ai/cmux/issues/6084).
extension MobilePairingStage {
    var title: String {
        switch self {
        case .network:
            return L10n.string("mobile.pairing.checklist.network.title", defaultValue: "Network")
        case .authentication:
            return L10n.string("mobile.pairing.checklist.authentication.title", defaultValue: "Authentication")
        case .trust:
            return L10n.string("mobile.pairing.checklist.trust.title", defaultValue: "Trust")
        }
    }

    /// The neutral one-line description shown while the gate is pending, in
    /// progress, or cleared (a failure replaces it with the actionable message).
    var detail: String {
        switch self {
        case .network:
            return L10n.string("mobile.pairing.checklist.network.detail", defaultValue: "Reaching your Mac")
        case .authentication:
            return L10n.string("mobile.pairing.checklist.authentication.detail", defaultValue: "Verifying your account")
        case .trust:
            return L10n.string("mobile.pairing.checklist.trust.detail", defaultValue: "Confirming it's your Mac")
        }
    }

    /// Stable suffix for the row's accessibility identifier, so UI tests can
    /// target a specific gate.
    var accessibilityIdentifierSuffix: String {
        switch self {
        case .network: return "network"
        case .authentication: return "authentication"
        case .trust: return "trust"
        }
    }
}

extension MobilePairingStageStatus {
    var symbolName: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    /// A localized status word appended to the gate's VoiceOver label, so the
    /// status is announced even though it is conveyed visually by icon + color.
    var accessibilityValue: String {
        switch self {
        case .pending:
            return L10n.string("mobile.pairing.checklist.status.pending", defaultValue: "Not started")
        case .inProgress:
            return L10n.string("mobile.pairing.checklist.status.inProgress", defaultValue: "In progress")
        case .succeeded:
            return L10n.string("mobile.pairing.checklist.status.succeeded", defaultValue: "Succeeded")
        case .failed:
            return L10n.string("mobile.pairing.checklist.status.failed", defaultValue: "Failed")
        }
    }
}
