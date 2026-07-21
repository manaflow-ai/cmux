import SwiftUI

struct ChatComposerTerminalFallbackRow: View {
    enum Kind {
        case ended
        case readOnly
    }

    let kind: Kind
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Text(
                    String(
                        localized: "chat.composer.open_terminal",
                        defaultValue: "Open terminal",
                        bundle: .module
                    )
                )
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch kind {
        case .ended:
            String(
                localized: "chat.composer.session_ended",
                defaultValue: "Session ended",
                bundle: .module
            )
        case .readOnly:
            String(
                localized: "chat.composer.read_only",
                defaultValue: "Read-only conversation",
                bundle: .module
            )
        }
    }
}
