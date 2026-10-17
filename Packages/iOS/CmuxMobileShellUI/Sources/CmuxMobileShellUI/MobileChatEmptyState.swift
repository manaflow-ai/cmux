import SwiftUI

/// The first-run Chat surface with one clear path into a new conversation.
struct MobileChatEmptyState: View {
    let onNewChat: () -> Void
    let onAddDevice: (() -> Void)?
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Start a chat", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Ask Codex, Claude, or OpenCode to work on your project.")
        } actions: {
            Button("New chat", action: onNewChat)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("MobileChatEmptyNewChat")
            if let onAddDevice {
                Button("Connect a computer", action: onAddDevice)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("MobileChatEmptyConnectComputer")
            }
            Button("Refresh chats", action: onRetry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("MobileChatEmptyRefresh")
        }
        .padding(.horizontal, 24)
    }
}

struct MobileChatConnectionPlaceholder: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to your computer…")
                .font(.headline)
            Text("Your chats will appear here when the connection is ready.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 38)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MobileChatInlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
