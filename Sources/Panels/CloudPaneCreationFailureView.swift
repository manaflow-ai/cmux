import SwiftUI

/// Mounts the latest cloud pane creation failure above one workspace's content.
struct CloudPaneCreationFailurePresentation: ViewModifier {
    @ObservedObject var workspace: Workspace

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let failure = workspace.cloudPaneCreationFailure {
                CloudPaneCreationFailureView(failure: failure) {
                    workspace.dismissCloudPaneCreationFailure(id: failure.id)
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// An inline, dismissible failure card for a cloud terminal creation request.
struct CloudPaneCreationFailureView: View {
    let failure: CloudPaneCreationFailure
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.errorText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text(failure.recoveryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK")) {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("CloudPaneCreationFailureDismiss")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityIdentifier("CloudPaneCreationFailure")
        .cloudErrorCopyMenu(failure.copyableText)
    }
}
