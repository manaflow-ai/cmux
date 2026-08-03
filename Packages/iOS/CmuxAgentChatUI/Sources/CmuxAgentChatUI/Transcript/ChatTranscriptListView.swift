#if os(iOS)
import CmuxAgentChat
import SwiftUI

/// Transitional SwiftUI shell around the fully native transcript table.
public struct ChatTranscriptListView: View {
    private let rows: [ChatTranscriptRow]
    private let agentState: ChatAgentState
    private let hasMoreHistory: Bool
    private let hasLoadedInitialHistory: Bool
    private let initialLoadFailed: Bool
    private let historyTruncatedAtHead: Bool
    private let actions: ChatRowActions
    private let onReachTop: () -> Void
    private let onRetryInitialLoad: () -> Void

    @Environment(\.chatTranscriptOverlayGeometry) private var overlayGeometry
    @State private var isAtBottom = true
    @State private var scrollToBottomRequest = 0

    public init(
        rows: [ChatTranscriptRow],
        agentState: ChatAgentState,
        hasMoreHistory: Bool,
        hasLoadedInitialHistory: Bool = true,
        initialLoadFailed: Bool = false,
        historyTruncatedAtHead: Bool = false,
        actions: ChatRowActions,
        onReachTop: @escaping () -> Void,
        onRetryInitialLoad: @escaping () -> Void = {}
    ) {
        self.rows = rows
        self.agentState = agentState
        self.hasMoreHistory = hasMoreHistory
        self.hasLoadedInitialHistory = hasLoadedInitialHistory
        self.initialLoadFailed = initialLoadFailed
        self.historyTruncatedAtHead = historyTruncatedAtHead
        self.actions = actions
        self.onReachTop = onReachTop
        self.onRetryInitialLoad = onRetryInitialLoad
    }

    public var body: some View {
        ChatTranscriptTableView(
            rows: rows,
            agentState: agentState,
            hasMoreHistory: hasMoreHistory,
            hasLoadedInitialHistory: hasLoadedInitialHistory,
            initialLoadFailed: initialLoadFailed,
            historyTruncatedAtHead: historyTruncatedAtHead,
            actions: actions,
            onReachTop: onReachTop,
            onRetryInitialLoad: onRetryInitialLoad,
            isAtBottom: $isAtBottom,
            scrollToBottomRequest: scrollToBottomRequest
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                ChatScrollToBottomButton {
                    isAtBottom = true
                    scrollToBottomRequest += 1
                }
                .padding(.trailing, 12)
                .padding(.bottom, max(8, ceil(overlayGeometry?.composerBottomInset ?? 0) + 8))
                .excludedFromKeyboardDismiss()
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
    }
}
#endif
