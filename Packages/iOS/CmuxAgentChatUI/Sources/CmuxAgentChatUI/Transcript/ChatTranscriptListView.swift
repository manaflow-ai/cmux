import CmuxAgentChat
import SwiftUI

/// The scrolling transcript: lazy rows, bottom-anchored auto-follow, an
/// unread-aware scroll-to-bottom pill, and top-edge history paging.
///
/// Follows the live tail only while the user is already at the bottom; any
/// upward scroll disengages following until the pill (or a send) re-engages
/// it (product rule: never steal scroll from a reading user).
///
/// Platform note: the precise at-bottom tracking uses the iOS 18 scroll
/// geometry APIs. The macOS 14 fallback (for the future desktop surface)
/// uses `ScrollViewReader` and always follows the tail.
public struct ChatTranscriptListView: View {
    private let rows: [ChatTranscriptRow]
    private let expandedIDs: Set<String>
    private let agentState: ChatAgentState
    private let hasMoreHistory: Bool
    private let hasLoadedInitialHistory: Bool
    private let initialLoadFailed: Bool
    private let historyTruncatedAtHead: Bool
    private let actions: ChatRowActions
    private let onReachTop: () -> Void
    private let onRetryInitialLoad: () -> Void

    @Environment(\.chatTheme) private var theme
    #if os(iOS)
    @Environment(\.chatTranscriptOverlayGeometry) private var overlayGeometry
    #endif

    #if os(iOS)
    @State private var isAtBottom = true
    @State private var scrollToBottomRequest = 0
    #endif
    @State private var containerWidth: CGFloat = 0

    /// Creates the transcript list.
    ///
    /// - Parameters:
    ///   - rows: The projected rows, oldest first.
    ///   - expandedIDs: Row ids currently expanded.
    ///   - agentState: Live agent presence (drives the typing indicator).
    ///   - hasMoreHistory: Whether a top sentinel should page older history.
    ///   - hasLoadedInitialHistory: Whether the first page has arrived
    ///     (drives the loading and empty placeholders).
    ///   - historyTruncatedAtHead: Whether paging stopped at the Mac's
    ///     cache head with older transcript left on disk.
    ///   - actions: Row action bundle.
    ///   - onReachTop: Called when the top sentinel appears (load older).
    public init(
        rows: [ChatTranscriptRow],
        expandedIDs: Set<String>,
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
        self.expandedIDs = expandedIDs
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
        #if os(iOS)
        ChatTranscriptTableView(
            rows: rows,
            expandedIDs: expandedIDs,
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
            Group {
                if !isAtBottom {
                    ChatScrollToBottomButton {
                        scrollToBottomRequest += 1
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, scrollToBottomButtonBottomPadding)
                    .excludedFromKeyboardDismiss()
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.snappy(duration: 0.2), value: isAtBottom)
        }
        #else
        ScrollViewReader { proxy in
            scrollContent
                .defaultScrollAnchor(.bottom)
                .onChange(of: rows.last?.id) { _, last in
                    guard let last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
        }
        #endif
    }

    private static let bottomAnchorID = "chat.bottom.anchor"

    #if os(iOS)
    private var scrollToBottomButtonBottomPadding: CGFloat {
        max(8, ceil(overlayGeometry?.composerBottomInset ?? 0) + 8)
    }
    #endif

    private var isWorking: Bool {
        if case .working = agentState { return true }
        return false
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if hasMoreHistory {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 12)
                        .onAppear(perform: onReachTop)
                } else if historyTruncatedAtHead {
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
                }
                if rows.isEmpty {
                    emptyPlaceholder
                }
                ForEach(rows) { row in
                    ChatTranscriptRowView(
                        row: row,
                        isExpanded: expandedIDs.contains(row.id),
                        actions: actions
                    )
                    .equatable()
                    .id(row.id)
                }
                if case .working = agentState {
                    ChatTypingIndicatorView(agentState: agentState)
                        .padding(.top, theme.intraGroupSpacing)
                }
                // Fixed trailing anchor: a stable scroll target for
                // tail-follow, the pill, and keyboard re-pin. It owns the
                // final bottom breathing room so `scrollTo(bottomAnchorID)`
                // lands at the true content end, not halfway through the last
                // visible row.
                Color.clear
                    .frame(height: 9)
                    .id(Self.bottomAnchorID)
            }
            .scrollTargetLayout()
            .padding(.horizontal, theme.horizontalMargin)
            .padding(.top, 8)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
        .environment(
            \.chatBubbleMaxWidth,
            containerWidth > 0 ? containerWidth * theme.bubbleMaxWidthFraction : .infinity
        )
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        if initialLoadFailed {
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
        } else if hasLoadedInitialHistory {
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
        } else {
            ProgressView()
                .controlSize(.regular)
                .padding(.vertical, 48)
        }
    }
}
