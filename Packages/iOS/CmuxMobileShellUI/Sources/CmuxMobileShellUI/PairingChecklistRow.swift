import CmuxMobileShellModel
import SwiftUI

struct PairingChecklistRow: View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.title)
        .accessibilityIdentifier("MobilePairingChecklistRow.\(stage.accessibilityIdentifierSuffix)")
        .accessibilityValue(status.accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        default:
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(status.tintColor)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityHint: String {
        switch (status.failureMessage, status.failureGuidance) {
        case let (message?, guidance?):
            return "\(message) \(guidance)"
        case let (message?, nil):
            return message
        case let (nil, guidance?):
            return guidance
        case (nil, nil):
            return stage.detail
        }
    }
}
