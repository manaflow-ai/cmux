import CmuxAgentConversation
public import SwiftUI
import Foundation

/// Renders one plain message bubble (user / assistant / reasoning / system).
///
/// `Equatable` so SwiftUI can skip re-evaluating its body when the snapshot is
/// unchanged. It holds only a ``MessageBubbleSnapshot`` value and a
/// ``ChatRowActions`` closure bundle, never a store reference, satisfying the
/// snapshot-boundary rule. `actions` is excluded from `==` because the closures
/// are stable above the list boundary.
public struct ChatMessageRowView: View, Equatable {
    /// The value to render.
    let snapshot: MessageBubbleSnapshot

    /// Closures for row interactions (copy).
    let actions: ChatRowActions

    /// Creates a message-bubble row.
    ///
    /// - Parameters:
    ///   - snapshot: The value to render.
    ///   - actions: Closures for row interactions.
    public init(snapshot: MessageBubbleSnapshot, actions: ChatRowActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    /// Compares only the value snapshot; closures are stable and excluded.
    nonisolated public static func == (lhs: ChatMessageRowView, rhs: ChatMessageRowView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    public var body: some View {
        HStack {
            if snapshot.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !snapshot.text.isEmpty {
                    Text(snapshot.text)
                        .font(snapshot.role == .reasoning ? .callout.italic() : .callout)
                        .foregroundStyle(snapshot.role == .reasoning ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if snapshot.imageCount > 0 {
                    Text(imageNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                Button(String(localized: "agentChat.copy", defaultValue: "Copy", bundle: .module)) {
                    actions.copyText(snapshot.text)
                }
                .disabled(snapshot.text.isEmpty)
            }
            if snapshot.role != .user { Spacer(minLength: 48) }
        }
    }

    /// The localized role label shown above the bubble.
    private var roleLabel: String {
        switch snapshot.role {
        case .user:
            return String(localized: "agentChat.role.user", defaultValue: "You", bundle: .module)
        case .assistant:
            return String(localized: "agentChat.role.assistant", defaultValue: "Agent", bundle: .module)
        case .reasoning:
            return String(localized: "agentChat.role.reasoning", defaultValue: "Reasoning", bundle: .module)
        case .system:
            return String(localized: "agentChat.role.system", defaultValue: "System", bundle: .module)
        case .toolResult:
            return String(localized: "agentChat.role.toolResult", defaultValue: "Tool result", bundle: .module)
        }
    }

    /// A localized note for image-only content (P1 does not load image bytes).
    private var imageNote: String {
        String(
            localized: "agentChat.imageAttachment",
            defaultValue: "Image attachment",
            bundle: .module
        )
    }

    /// The bubble background, tinted for user vs others.
    private var bubbleBackground: Color {
        switch snapshot.role {
        case .user:
            return Color.accentColor.opacity(0.15)
        case .system:
            return Color.secondary.opacity(0.08)
        default:
            return Color.secondary.opacity(0.12)
        }
    }
}
