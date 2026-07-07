#if os(iOS)
import CmuxAgentChat
import Foundation
import SwiftUI

struct ChatTranscriptTableConfiguration {
    let rows: [ChatTranscriptRow]
    let expandedIDs: Set<String>
    let agentState: ChatAgentState
    let hasMoreHistory: Bool
    let hasLoadedInitialHistory: Bool
    let initialLoadFailed: Bool
    let historyTruncatedAtHead: Bool
    let actions: ChatRowActions
    let onReachTop: () -> Void
    let onRetryInitialLoad: () -> Void
    let theme: ChatTheme
    let markdownRenderer: ChatMarkdownRenderer?
    let contentCache: ChatContentCache?

    func makeItems() -> [ChatTranscriptTableItem] {
        var items: [ChatTranscriptTableItem] = []
        if hasMoreHistory {
            items.append(.loadingMore)
        } else if historyTruncatedAtHead {
            items.append(.historyTruncated)
        }
        if rows.isEmpty {
            if initialLoadFailed {
                items.append(.loadFailed)
            } else if hasLoadedInitialHistory {
                items.append(.empty)
            } else {
                items.append(.initialLoading)
            }
        }
        items.append(contentsOf: rows.map(ChatTranscriptTableItem.row))
        if case .working = agentState {
            items.append(.typing)
        }
        items.append(.bottomAnchor)
        return items
    }

    @ViewBuilder
    func view(for item: ChatTranscriptTableItem, tableWidth: CGFloat) -> some View {
        itemView(for: item)
            .padding(.horizontal, theme.horizontalMargin)
            .environment(\.chatTheme, theme)
            .environment(\.chatMarkdownRenderer, markdownRenderer)
            .environment(\.chatContentCache, contentCache)
            .environment(
                \.chatBubbleMaxWidth,
                tableWidth > 0 ? tableWidth * theme.bubbleMaxWidthFraction : .infinity
            )
    }

    @ViewBuilder
    private func itemView(for item: ChatTranscriptTableItem) -> some View {
        switch item {
        case .loadingMore:
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 12)
        case .historyTruncated:
            Text(
                String(
                    localized: "chat.history.truncated",
                    defaultValue: "Earlier history is on your Mac",
                    bundle: .module
                )
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 12)
        case .loadFailed:
            VStack(spacing: 12) {
                Text(
                    String(
                        localized: "chat.transcript.load_failed",
                        defaultValue: "Couldn't load this conversation",
                        bundle: .module
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Button(action: onRetryInitialLoad) {
                    Text(
                        String(localized: "chat.transcript.retry", defaultValue: "Retry", bundle: .module)
                    )
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ChatTranscriptRetry")
            }
            .padding(.vertical, 48)
        case .empty:
            Text(
                String(
                    localized: "chat.transcript.empty",
                    defaultValue: "No messages yet",
                    bundle: .module
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 48)
        case .initialLoading:
            ProgressView()
                .controlSize(.regular)
                .padding(.vertical, 48)
        case .row(let row):
            ChatTranscriptRowView(
                row: row,
                isExpanded: expandedIDs.contains(row.id),
                actions: actions
            )
            .equatable()
        case .typing:
            ChatTypingIndicatorView(agentState: agentState)
                .padding(.top, theme.intraGroupSpacing)
        case .bottomAnchor:
            Color.clear
                .frame(height: 9)
        }
    }
}

enum ChatTranscriptTableItem: Equatable {
    case loadingMore
    case historyTruncated
    case loadFailed
    case empty
    case initialLoading
    case row(ChatTranscriptRow)
    case typing
    case bottomAnchor

    var id: String {
        switch self {
        case .loadingMore:
            return "loading-more"
        case .historyTruncated:
            return "history-truncated"
        case .loadFailed:
            return "load-failed"
        case .empty:
            return "empty"
        case .initialLoading:
            return "initial-loading"
        case .row(let row):
            return row.id
        case .typing:
            return "typing"
        case .bottomAnchor:
            return "bottom-anchor"
        }
    }
}

#endif
