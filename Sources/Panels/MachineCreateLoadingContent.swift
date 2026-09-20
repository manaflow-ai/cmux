import SwiftUI

/// A truthful reservation surface using the same operation and actions as the machine row.
struct MachineCreateLoadingContent: View {
    let operation: MachineCreateOperation
    let actions: MachineCreateRowActions

    var body: some View {
        VStack(spacing: 14) {
            if operation.failureOutput == nil {
                ProgressView().controlSize(.small)
            }
            Text(operation.request.displayName)
                .cmuxFont(size: 14, weight: .semibold)
            Text(operation.statusLabel)
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
            if let output = operation.failureOutput {
                Text(output)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(String(localized: "machines.pending.retry", defaultValue: "Retry")) { actions.retry(operation.id) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss")) { actions.dismiss(operation.id) }
                        .buttonStyle(.bordered)
                }
            } else if operation.isCancellable {
                Button(String(localized: "machines.pending.cancel", defaultValue: "Cancel")) { actions.cancel(operation.id) }
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
    }
}
