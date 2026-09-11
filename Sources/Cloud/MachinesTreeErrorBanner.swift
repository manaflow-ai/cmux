import AppKit
import SwiftUI

/// Operation errors have their own dismissible row so they cannot crowd out create controls.
struct MachinesTreeErrorBanner: View {
    let failure: CloudTreeOperationErrorState.Failure
    let dismiss: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message)
                    .cmuxFont(size: 11)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "machines.treeError.details", defaultValue: "Details…")) {
                    showsDetails = true
                }
                .buttonStyle(.plain)
                .cmuxFont(size: 11)
                .underline()
                .accessibilityIdentifier("CloudMachinesErrorDetails")
                .popover(isPresented: $showsDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "machines.treeError.title", defaultValue: "Cloud action failed"))
                            .cmuxFont(size: 13, weight: .semibold)
                        ScrollView {
                            Text(failure.message)
                                .cmuxFont(size: 12)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        Text(String(localized: "machines.treeError.recovery", defaultValue: "Refresh to check the current state before trying the action again."))
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "machines.pending.copyError", defaultValue: "Copy Error")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(failure.message, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                    .frame(width: 320)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MachinesChromeIconButton(
                symbolName: "xmark",
                accessibilityLabel: String(localized: "machines.treeError.dismiss", defaultValue: "Dismiss Error"),
                isBusy: false,
                action: dismiss
            )
            .accessibilityIdentifier("CloudMachinesDismissError")
        }
        .foregroundStyle(.orange.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("CloudMachinesOperationError")
    }
}
