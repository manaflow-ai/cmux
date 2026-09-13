import SwiftUI

struct SudoApprovalReviewView: View {
    let presentation: SudoApprovalPresentation
    let approve: @MainActor @Sendable () async -> Void
    let deny: @MainActor @Sendable () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(presentation.heading, systemImage: "lock.shield")
                .font(.title2.weight(.semibold))

            Text(presentation.warning)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                metadataRow(presentation.requestIDLabel, presentation.request.id)
                metadataRow(presentation.reasonLabel, presentation.request.reason)
                metadataRow(presentation.requesterLabel, presentation.requesterSummary)
                metadataRow(
                    presentation.workingDirectoryLabel,
                    presentation.request.currentDirectory
                )
                metadataRow(presentation.queuedLabel, presentation.createdAtSummary)
            }

            Text(presentation.scriptLabel)
                .font(.headline)

            SudoScriptTextView(
                script: presentation.script,
                accessibilityLabel: presentation.scriptLabel
            )
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }
            .frame(minHeight: 220)

            HStack(spacing: 10) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(presentation.status)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(presentation.denyButtonTitle) {
                    Task { await deny() }
                }
                .disabled(!presentation.canDecide)
                Button(presentation.approveButtonTitle) {
                    Task { await approve() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!presentation.canDecide)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
