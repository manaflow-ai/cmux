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
            Label(title(for: action), systemImage: systemImage(for: action))
        }
        .disabled(isRunning || disabledActions.contains(action))
    }

    private func title(for action: ChatArtifactAction) -> String {
        switch action {
        case .share:
            String(localized: "chat.artifact.share", defaultValue: "Share", bundle: .module)
        case .save:
            String(localized: "chat.artifact.save_to_files", defaultValue: "Save to Files", bundle: .module)
        case .copyImage:
            String(localized: "chat.artifact.copy_image", defaultValue: "Copy image", bundle: .module)
        case .copyContents:
            String(localized: "chat.artifact.copy_contents", defaultValue: "Copy contents", bundle: .module)
        case .copyPath:
            String(localized: "chat.artifact.copy_path", defaultValue: "Copy path", bundle: .module)
        }
    }

    private func systemImage(for action: ChatArtifactAction) -> String {
        switch action {
        case .share:
            "square.and.arrow.up"
        case .save:
            "folder.badge.plus"
        case .copyImage:
            "photo.on.rectangle"
        case .copyContents:
            "doc.on.doc"
        case .copyPath:
            "link"
        }
    }
}
#endif
