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
/// The transcript follows live updates: while the user is at the bottom, new
/// messages keep the view pinned to the bottom; once they scroll up, their
/// position is preserved. When a ``ChatComposerActions`` bundle is injected,
/// an input bar is shown that routes drafts to the agent's terminal.
///
/// ```swift
/// AgentChatView(source: source, composer: composerActions)
/// ```
public struct AgentChatView: View {
    /// The view model, seeded from the injected source.
    @State private var model: ConversationViewModel

    /// Whether the user is currently scrolled to the bottom of the transcript.
    @State private var isAtBottom: Bool = true

    /// The injected composer wiring, or `nil` to hide the input bar.
    private let composer: ChatComposerActions?

    /// The scroll id of the bottom-of-transcript marker.
    private static let bottomMarkerID = "agentChat.bottomMarker"

    /// Creates a chat view bound to a conversation source.
    ///
    /// - Parameters:
    ///   - source: The source whose conversation to render.
    ///   - composer: The send wiring for the input bar, or `nil` (the default)
    ///     to present a read-only transcript.
    public init(source: any ConversationSource, composer: ChatComposerActions? = nil) {
        _model = State(initialValue: ConversationViewModel(source: source))
        self.composer = composer
    }

    public var body: some View {
        // Build the closure bundle here, above the list boundary, capturing the
        // model once so no row holds a model reference.
        let actions = ChatRowActions(
            isToolCallExpanded: { model.isToolCallExpanded($0) },
            toggleToolCall: { model.toggleToolCall($0) },
            copyText: { Self.copyToPasteboard($0) }
        )

        VStack(spacing: 0) {
            if model.rows.isEmpty {
                emptyState
            } else {
                transcript(actions: actions)
            }
            if let composer {
                Divider()
                ChatComposerView(actions: composer)
            }
        }
        .task {
            await model.run()
        }
    }

    /// The scrolling transcript with bottom-follow behavior.
    private func transcript(actions: ChatRowActions) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.rows) { row in
                        rowView(row, actions: actions)
                    }
                    // Sentinel tracking whether the user is at the bottom; its
                    // lazy-container visibility drives the follow behavior.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomMarkerID)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(12)
            }
            // Open at the latest turn, like any chat surface.
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.conversation.seq) {
                // New content: keep following only if the user was at the
                // bottom; otherwise preserve their reading position.
                if isAtBottom {
                    proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                }
            }
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
