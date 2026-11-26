#if os(iOS)
import SwiftUI

/// Renders artifact actions as menu rows or compact inline controls.
struct ChatArtifactActionBar: View {
    enum Style {
        case menu
        case compact
    }

    let actions: [ChatArtifactAction]
    let style: Style
    let disabledActions: Set<ChatArtifactAction>
    let isRunning: Bool
    let onAction: @MainActor (ChatArtifactAction) -> Void

    var body: some View {
        switch style {
        case .menu:
            Group {
                ForEach(actions, id: \.self) { action in
                    actionButton(action)
                }
            }
        case .compact:
            HStack(spacing: 8) {
                ForEach(actions, id: \.self) { action in
                    actionButton(action)
                }
            }
            .padding(4)
            .background(.thinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ChatArtifactAction) -> some View {
        switch style {
        case .menu:
            baseButton(action)
        case .compact:
            baseButton(action)
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        }
    }

    private func baseButton(_ action: ChatArtifactAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(action.localizedTitle, systemImage: action.systemImage)
        }
        .disabled(isRunning || disabledActions.contains(action))
    }
}
#endif
