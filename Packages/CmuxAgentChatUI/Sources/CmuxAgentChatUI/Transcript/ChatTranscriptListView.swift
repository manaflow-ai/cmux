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
    private let historyTruncatedAtHead: Bool
    private let actions: ChatRowActions
    private let onReachTop: () -> Void

    @Environment(\.chatTheme) private var theme

    #if os(iOS)
    @State private var isAtBottom = true
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
        historyTruncatedAtHead: Bool = false,
        actions: ChatRowActions,
        onReachTop: @escaping () -> Void
    ) {
        self.rows = rows
        self.expandedIDs = expandedIDs
        self.agentState = agentState
        self.hasMoreHistory = hasMoreHistory
        self.hasLoadedInitialHistory = hasLoadedInitialHistory
        self.historyTruncatedAtHead = historyTruncatedAtHead
        self.actions = actions
        self.onReachTop = onReachTop
    }

    public var body: some View {
        #if os(iOS)
        // ScrollViewReader (not ScrollPosition): `ScrollPosition.scrollTo`
        // silently no-ops on this content (verified empirically on device
        // geometry — offset never moved), which killed both the pill and
        // tail-follow. The proxy + row-id path scrolls reliably.
        ScrollViewReader { proxy in
            scrollContent
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                // Composite key: a failed pending row pinned at the tail
                // keeps `last?.id` stable while agent messages insert
                // above it, so follow on count changes too.
                .onChange(of: FollowKey(count: rows.count, lastID: rows.last?.id)) {
                    guard isAtBottom else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom {
                        ChatScrollToBottomButton {
                            withAnimation(.snappy(duration: 0.25)) {
                                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 8)
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

    /// Tail-follow trigger identity; see the onChange comment.
    private struct FollowKey: Equatable {
        let count: Int
        let lastID: String?
    }

    private static let bottomAnchorID = "chat.bottom.anchor"

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
                // Fixed trailing anchor, doing double duty: a stable
                // scroll target for tail-follow (scrolling to the last
                // row's id undershoots from lazy height estimation), and a
                // semantic at-bottom detector — its materialization is the
                // truth, where scroll-geometry inset math proved
                // unreliable across inset configurations.
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
                    #if os(iOS)
                    .onAppear { isAtBottom = true }
                    .onDisappear { isAtBottom = false }
                    #endif
            }
            .scrollTargetLayout()
            .padding(.horizontal, theme.horizontalMargin)
            .padding(.vertical, 8)
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
        if hasLoadedInitialHistory {
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
