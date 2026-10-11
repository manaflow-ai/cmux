import CmuxCloud
import CmuxFoundation
import SwiftUI

/// The machine menu's Network sheet: the shared editor over the stored
/// policy, the provider's applied state beside the buttons, and Save.
struct CloudNetworkPolicySheet: View {
    @Bindable var model: CloudNetworkPolicySheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(
                format: String(localized: "cloud.network.sheet.title", defaultValue: "Network for %@"),
                model.machineLabel
            ))
            .cmuxFont(size: 15, weight: .semibold)
            .lineLimit(1)
            .truncationMode(.middle)

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
                CloudNetworkPolicyEditor(model: model.editor)
            }

            if let error = model.saveError {
                messageBox(error, isError: true)
                    .accessibilityIdentifier("CloudNetworkPolicySheet.saveError")
            }

            buttons
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("CloudNetworkPolicySheet")
    }

    /// Whether the provider applied the stored policy: an icon and one word
    /// beside the buttons; the time and any provider error are the tooltip.
    @ViewBuilder
    private var appliedStatus: some View {
        if let applied = model.applied {
            let detail = [applied.state == .applied ? applied.appliedAt : nil, applied.error]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: "\n")
            HStack(spacing: 4) {
                Image(systemName: applied.state == .applied ? "checkmark.circle.fill"
                    : applied.state == .pending ? "clock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(applied.state == .failed ? Color.red : Color.secondary)
                Text(applied.title)
                    .cmuxFont(size: 11)
                    .foregroundStyle(applied.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            .help(detail.isEmpty ? applied.title : detail)
            .accessibilityElement(children: .combine)
            .accessibilityHint(detail)
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

    /// "Changes apply without restarting" is Save's tooltip, not a footer line.
    private var buttons: some View {
        HStack(spacing: 8) {
            appliedStatus
            Spacer()
            if model.outcome == nil, model.applied?.state == .pending, !model.hasChanges {
                Button(String(localized: "cloud.network.sheet.done", defaultValue: "Done")) { model.done() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "machines.new.cancel", defaultValue: "Cancel")) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("CloudNetworkPolicySheet.cancel")
            }
            Button(String(localized: "cloud.network.sheet.save", defaultValue: "Save")) {
                Task { await model.save() }
            }
            .disabled(!model.canSave)
            .keyboardShortcut(.defaultAction)
            .help(String(localized: "cloud.network.sheet.live", defaultValue: "Changes apply without restarting the machine."))
            .accessibilityIdentifier("CloudNetworkPolicySheet.save")
        }
        .padding(.top, 4)
    }
}
