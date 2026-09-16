import CmuxSimulator
import SwiftUI

struct SimulatorToolFeedbackView: View {
    let isWorking: Bool
    let failure: SimulatorFailure?

    var body: some View {
        if isWorking {
            ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text(simulatorStrings.loading))
        }
        if let failure {
            VStack(alignment: .leading, spacing: 8) {
                SimulatorLocalizedLabel(simulatorStrings.controlFailed, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(simulatorStrings.failure(failure.code))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup {
                    Text(verbatim: failure.code)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } label: {
                    Text(simulatorStrings.technicalDetails)
                        .font(.caption)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}
