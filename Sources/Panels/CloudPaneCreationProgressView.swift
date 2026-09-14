import SwiftUI

/// Non-blocking status for the newest Cloud terminal open request in a workspace.
struct CloudPaneCreationProgressView: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(String(localized: "cloudTerminal.creation.starting", defaultValue: "Starting Cloud terminal"))
                .font(.subheadline)
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(String(localized: "common.close", defaultValue: "Close"))
            .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("CloudPaneCreationProgress")
    }
}
