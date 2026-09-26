import SwiftUI

/// A truthful reservation surface using the same operation and actions as the machine row.
struct MachineCreateLoadingContent: View {
    let operation: MachineCreateOperation
    let actions: MachineCreateRowActions
    let elapsedSeconds: Int

    var body: some View {
        VStack(spacing: 16) {
            if operation.failureOutput == nil {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Text(operation.request.displayName)
                .cmuxFont(size: 18, weight: .semibold)
            Text(operation.statusLabel)
                .cmuxFont(size: 13, weight: .medium)
                .foregroundStyle(.secondary)
            Text(String(format: String(
                localized: "panel.cloudVM.loading.elapsed",
                defaultValue: "%ds elapsed"
            ), elapsedSeconds))
            .cmuxFont(size: 11)
            .foregroundStyle(.tertiary)
            if let output = operation.failureOutput {
                Text(output)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(String(localized: "machines.pending.retry", defaultValue: "Retry")) { actions.retry(operation.id) }
                        .buttonStyle(.borderedProminent)
            .backport.pointerStyle(.link)
                    Button(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss")) { actions.dismiss(operation.id) }
                        .buttonStyle(.bordered)
            .backport.pointerStyle(.link)
                }
            } else {
                Text(String(localized: "machines.new.background.note", defaultValue: "Creation continues in the Machines panel."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
    }
}
