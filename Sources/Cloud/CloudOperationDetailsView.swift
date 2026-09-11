import AppKit
import SwiftUI

struct CloudOperationDetailsView: View {
    let operations: [CloudOperationSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "cloud.operation.details", defaultValue: "Cloud activity and errors"))
                .font(.headline)
            Text(String(localized: "cloud.operation.diagnosticsNotice", defaultValue: "Cloud sends connection timing and error codes while you are signed in. Terminal content and credentials are excluded."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(operations.reversed())) { operation in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(operation.operation.label).font(.subheadline.bold())
                                Spacer()
                                Text(operation.startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(operation.steps) { step in
                                HStack {
                                    Image(systemName: step.outcome == nil ? "clock" : step.outcome == .success ? "checkmark" : "exclamationmark.triangle")
                                        .foregroundStyle(step.outcome == .failure || step.outcome == .timeout ? Color.orange : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(step.phase.label)
                                        if let failure = step.failure { Text(failure.label).foregroundStyle(.orange) }
                                    }
                                    Spacer()
                                    if let duration = step.durationMs { Text(Duration.milliseconds(duration), format: .units(allowed: [.seconds, .milliseconds], width: .abbreviated)) }
                                }
                                .font(.caption)
                            }
                            if operation.needsAttention {
                                Text(String(localized: "cloud.operation.failedAction", defaultValue: "This operation did not complete. Check the machine state before you try it again."))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Button(String(localized: "cloud.operation.copyReference", defaultValue: "Copy diagnostic reference")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(operation.reference, forType: .string)
                            }
                            .font(.caption)
                        }
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 420)
        .accessibilityIdentifier("CloudOperationDetails")
    }
}
