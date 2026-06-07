public import CmuxAgentConversation
public import SwiftUI
import Foundation

/// The entry view for the structured agent chat.
///
/// Owns a ``ConversationViewModel`` as `@State`, builds the ``ChatRowActions``
/// closure bundle once above the `LazyVStack` boundary, and renders the
/// projected ``MessageRowSnapshot`` rows. The rows below the boundary receive
/// only value snapshots and those stable closures, never the model.
///
/// ```swift
/// AgentChatView(source: LocalTranscriptConversationSource(...))
/// ```
public struct AgentChatView: View {
    /// The view model, seeded from the injected source.
    @State private var model: ConversationViewModel

    /// Creates a chat view bound to a conversation source.
    ///
    /// - Parameter source: The source whose conversation to render.
    public init(source: any ConversationSource) {
        _model = State(initialValue: ConversationViewModel(source: source))
    }

    public var body: some View {
        // Build the closure bundle here, above the list boundary, capturing the
        // model once so no row holds a model reference.
        let actions = ChatRowActions(
            isToolCallExpanded: { model.isToolCallExpanded($0) },
            toggleToolCall: { model.toggleToolCall($0) },
            copyText: { Self.copyToPasteboard($0) }
        )

        Group {
            if model.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.rows) { row in
                            rowView(row, actions: actions)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task {
            await model.run()
        }
    }

    /// Renders one projected row by its kind.
    @ViewBuilder
    private func rowView(_ row: MessageRowSnapshot, actions: ChatRowActions) -> some View {
        switch row.kind {
        case let .message(bubble):
            ChatMessageRowView(snapshot: bubble, actions: actions)
                .equatable()
        case let .toolCall(toolCall):
            ToolCallRowView(
                snapshot: toolCall,
                isExpanded: model.isToolCallExpanded(toolCall.callID),
                actions: actions
            )
            .equatable()
        }
    }

    /// The placeholder shown before any content is available or when the
    /// transcript has no renderable messages.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(
                model.hasLoaded
                    ? String(
                        localized: "agentChat.empty.noMessages",
                        defaultValue: "No conversation found for this terminal.",
                        bundle: .module
                    )
                    : String(
                        localized: "agentChat.empty.loading",
                        defaultValue: "Loading conversation…",
                        bundle: .module
                    )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Copies text to the platform pasteboard.
    private static func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

#if canImport(AppKit)
private import AppKit
#elseif canImport(UIKit)
private import UIKit
#endif
