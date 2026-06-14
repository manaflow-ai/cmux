import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The network / authentication / trust pairing checklist: one resolving check
/// mark per gate so the user can see exactly which stage of pairing succeeded or
/// failed, instead of one opaque "could not connect"
/// (https://github.com/manaflow-ai/cmux/issues/6084).
///
/// A pure value view — it takes the immutable ``MobilePairingChecklist`` snapshot
/// and renders it, holding no store reference, so it is safe to embed in the
/// pairing form.
struct PairingChecklistRows: View {
    let checklist: MobilePairingChecklist

    var body: some View {
        ForEach(MobilePairingStage.allCases, id: \.self) { stage in
            PairingChecklistRow(stage: stage, status: checklist.status(for: stage))
        }
    }
}

private struct PairingChecklistRow: View {
    let stage: MobilePairingStage
    let status: MobilePairingStageStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let message = status.failureMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                    if let guidance = status.failureGuidance {
                        Text(guidance)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(stage.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobilePairingChecklistRow.\(stage.accessibilityIdentifierSuffix)")
        .accessibilityValue(status.accessibilityValue)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        default:
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(status.tintColor)
        }
    }
}
