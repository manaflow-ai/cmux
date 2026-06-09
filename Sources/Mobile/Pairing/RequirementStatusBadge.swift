import SwiftUI

/// The one status indicator used by every requirements-checklist row in
/// ``MobilePairingView``, so the checklist's visual language stays consistent.
/// Meaning is carried by both the symbol shape and its color (never color
/// alone): red exclamation for a blocking step, green check for a completed
/// one, a neutral dashed circle while the step can't be evaluated yet.
struct RequirementStatusBadge: View {
    let status: MobilePairingModel.RequirementStatus

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(tint)
            .frame(width: 18)
            .accessibilityLabel(label)
    }

    private var symbolName: String {
        switch status {
        case .complete: return "checkmark.circle.fill"
        case .needsAction: return "exclamationmark.circle.fill"
        case .pending: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch status {
        case .complete: return .green
        case .needsAction: return .red
        case .pending: return .secondary
        }
    }

    private var label: String {
        switch status {
        case .complete:
            return String(localized: "mobile.pairing.req.status.done", defaultValue: "Done")
        case .needsAction:
            return String(localized: "mobile.pairing.req.status.needsAttention", defaultValue: "Needs attention")
        case .pending:
            return String(localized: "mobile.pairing.req.status.checking", defaultValue: "Checking")
        }
    }
}
