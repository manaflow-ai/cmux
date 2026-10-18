import CmuxCloud
import CmuxFoundation
import SwiftUI

/// The machine the sheet is about: how many of its secrets are current,
/// when they were last delivered, Sync now, the last error, and names the
/// next sync will remove. Per-name state is on each row of the list.
struct CloudSecretsMachineStatusView: View {
    @Bindable var model: CloudSecretsSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CloudSecretsSheetPresentation.machineSummary(model.statusRows, isDelivering: model.isDelivering))
                        .cmuxFont(size: 12, weight: .medium)
                        .lineLimit(1)
                    Text(CloudSecretsSheetPresentation.deliveredLabel(model.delivery?.deliveredAt, now: model.currentDate))
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(String(localized: "cloudSecrets.machine.syncNow", defaultValue: "Sync Now")) {
                    Task { await model.syncNow() }
                }
                .disabled(model.isDelivering || model.hasModalCard)
                .help(String(localized: "cloudSecrets.machine.syncNow.help", defaultValue: "Send this machine its current secrets over its encrypted link."))
                .accessibilityIdentifier("CloudSecretsMachineStatus.sync")
            }
            .accessibilityElement(children: .contain)

            if let error = model.syncError ?? model.delivery?.lastError ?? model.statusError {
                CloudSecretsMessageBox(text: error, isError: true)
                    .accessibilityIdentifier("CloudSecretsMachineStatus.error")
            }

            if !model.extraNames.isEmpty {
                Text(String(
                    format: String(localized: "cloudSecrets.machine.extra", defaultValue: "The next sync removes: %@"),
                    model.extraNames.joined(separator: ", ")
                ))
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudSecretsMachineStatus.extra")
            }

            Text(String(localized: "cloudSecrets.machine.newTerminal", defaultValue: "Open a new terminal to use updated values. Shells that are already open keep the values they started with."))
                .cmuxFont(size: 11)
                .foregroundStyle(model.didSync ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .accessibilityIdentifier("CloudSecretsMachineStatus")
    }

    private var hasError: Bool {
        (model.syncError ?? model.delivery?.lastError) != nil
    }

    /// A spinner while a delivery runs; otherwise the state's symbol.
    @ViewBuilder
    private var statusIcon: some View {
        if model.isDelivering {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusTint)
        }
    }

    private var statusSymbol: String {
        if hasError { return "exclamationmark.triangle.fill" }
        return CloudSecretsSheetPresentation.needsSync(model.statusRows) ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if hasError { return .red }
        return CloudSecretsSheetPresentation.needsSync(model.statusRows) ? .orange : .green
    }
}
