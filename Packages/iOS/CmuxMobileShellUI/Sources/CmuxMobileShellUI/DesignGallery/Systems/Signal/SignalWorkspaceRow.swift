#if DEBUG
import SwiftUI

/// Renders a workspace in Signal's fixed name, state, and elapsed columns.
struct SignalWorkspaceRow: View {
    let workspace: GalleryWorkspaceFixture
    let theme: SignalTheme

    @State private var showsActions = false

    private var status: SignalStatusStyle {
        SignalStatusStyle(state: workspace.state, theme: theme)
    }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 0) {
                SignalStatusRail(style: status)

                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name)
                        .font(.system(.subheadline, design: .default, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text(workspace.branch)
                        .font(.system(.footnote, design: .monospaced, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        SignalStatusSquare(color: status.color)
                        Text(status.label)
                            .font(.system(.caption2, design: .default, weight: .semibold))
                            .tracking(0.88)
                    }
                    Text(workspace.agentName)
                        .font(.system(.footnote, design: .monospaced, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                }
                .foregroundStyle(theme.ink)
                .frame(width: 92, alignment: .leading)

                Text(workspace.absoluteTimeText)
                    .font(.system(.footnote, design: .monospaced, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 52, alignment: .trailing)
                    .padding(.trailing, 10)
            }
            .frame(minHeight: 44)
            .background(theme.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(SignalRowButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in showsActions = true }
        )
        .confirmationDialog(
            workspace.branch,
            isPresented: $showsActions,
            titleVisibility: .visible
        ) {
            Button("Open", action: {})
            Button("Copy Branch", action: {})
            Button("Cancel", role: .cancel, action: {})
        } message: {
            Text(workspace.pendingQuestion ?? workspace.detailText)
        }
        .accessibilityLabel("\(workspace.name), \(workspace.branch), \(status.label), \(workspace.absoluteTimeText)")
    }
}
#endif
