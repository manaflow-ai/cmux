import AppKit
import SwiftUI

struct CloudOperationDetailsView: View {
    let operations: [CloudOperationSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "cloud.diagnostics.title", defaultValue: "Cloud Diagnostics"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "cloud.diagnostics.copy", defaultValue: "Copy Diagnostics")) {
                    CloudErrorCopy.copy(CloudDiagnosticReport.text(operations: operations))
                }
                .accessibilityIdentifier("CloudDiagnosticsCopy")
            }
            Text(String(localized: "cloud.operation.diagnosticsNotice", defaultValue: "Cloud sends connection timing and error codes while you are signed in. Terminal content and credentials are excluded."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if operations.isEmpty {
                        Text(String(localized: "cloud.diagnostics.empty", defaultValue: "No Cloud activity recorded in this session."))
                            .foregroundStyle(.secondary)
                    }
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
                                .cloudErrorCopyMenu(step.failure != nil || step.outcome == .failure || step.outcome == .timeout
                                    ? CloudDiagnosticReport.stepText(step) + "\n" + operation.reference : nil)
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
                        .cloudErrorCopyMenu(operation.needsAttention || operation.steps.contains(where: { $0.outcome == .failure || $0.outcome == .timeout })
                            ? operation.copyableError : nil)
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
