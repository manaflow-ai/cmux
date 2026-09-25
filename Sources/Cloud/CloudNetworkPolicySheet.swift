import CmuxFoundation
import SwiftUI

/// The machine menu's Network sheet: the shared editor over the stored
/// policy, the provider's applied state, and Save.
struct CloudNetworkPolicySheet: View {
    @Bindable var model: CloudNetworkPolicySheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(
                    format: String(localized: "cloud.network.sheet.title", defaultValue: "Network for %@"),
                    model.machineLabel
                ))
                .cmuxFont(size: 19, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                CloudSecurityExplainer()
            }

            switch model.phase {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "cloud.network.sheet.loading", defaultValue: "Loading the network policy…"))
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                }
            case .loadFailed(let message):
                messageBox(message, isError: true)
            case .ready:
                CloudNetworkPolicyEditor(model: model.editor, detailsInitiallyExpanded: true)
                appliedRow
            }

            if let error = model.saveError {
                messageBox(error, isError: true)
                    .accessibilityIdentifier("CloudNetworkPolicySheet.saveError")
            }

            buttons
        }
        .padding(24)
        .frame(width: 500)
        .accessibilityIdentifier("CloudNetworkPolicySheet")
    }

    @ViewBuilder
    private var appliedRow: some View {
        if let applied = model.applied {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: applied.state == .applied ? "checkmark.circle.fill"
                        : applied.state == .pending ? "clock" : "exclamationmark.triangle.fill")
                        .foregroundStyle(applied.state == .failed ? Color.red : Color.secondary)
                    Text(applied.title)
                        .cmuxFont(size: 11, weight: .medium)
                    if let appliedAt = applied.appliedAt, applied.state == .applied {
                        Text(appliedAt)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let error = applied.error, !error.isEmpty {
                    Text(error)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("CloudNetworkPolicySheet.applied")
        }
    }

    private func messageBox(_ text: String, isError: Bool) -> some View {
        Text(text)
            .cmuxFont(size: 11)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(isError ? 0.08 : 0)))
            .cloudErrorCopyMenu(text)
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                Text(String(localized: "cloud.network.sheet.live", defaultValue: "Changes apply without restarting the machine."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer()
                if model.outcome == nil, model.applied?.state == .pending, !model.hasChanges {
                    Button(String(localized: "cloud.network.sheet.done", defaultValue: "Done")) { model.done() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                } else {
                    Button(String(localized: "machines.new.cancel", defaultValue: "Cancel")) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("CloudNetworkPolicySheet.cancel")
                }
                Button(String(localized: "cloud.network.sheet.save", defaultValue: "Save")) {
                    Task { await model.save() }
                }
                .disabled(!model.canSave)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("CloudNetworkPolicySheet.save")
            }
        }
    }
}
