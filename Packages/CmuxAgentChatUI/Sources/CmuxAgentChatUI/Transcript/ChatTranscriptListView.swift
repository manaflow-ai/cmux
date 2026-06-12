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
    private let actions: ChatRowActions
    private let onReachTop: () -> Void

    @Environment(\.chatTheme) private var theme

    #if os(iOS)
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    #endif

    /// Creates the transcript list.
    ///
    /// - Parameters:
    ///   - rows: The projected rows, oldest first.
    ///   - expandedIDs: Row ids currently expanded.
    ///   - agentState: Live agent presence (drives the typing indicator).
    ///   - hasMoreHistory: Whether a top sentinel should page older history.
    ///   - actions: Row action bundle.
    ///   - onReachTop: Called when the top sentinel appears (load older).
    public init(
        rows: [ChatTranscriptRow],
        expandedIDs: Set<String>,
        agentState: ChatAgentState,
        hasMoreHistory: Bool,
        actions: ChatRowActions,
        onReachTop: @escaping () -> Void
    ) {
        self.rows = rows
        self.expandedIDs = expandedIDs
        self.agentState = agentState
        self.hasMoreHistory = hasMoreHistory
        self.actions = actions
        self.onReachTop = onReachTop
    }

    public var body: some View {
        #if os(iOS)
        scrollContent
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return distanceFromBottom <= 80
            } action: { _, nearBottom in
                isAtBottom = nearBottom
            }
            .onChange(of: rows.last?.id) {
                guard isAtBottom else { return }
                scrollPosition.scrollTo(edge: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    ChatScrollToBottomButton {
                        withAnimation(.snappy(duration: 0.25)) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.snappy(duration: 0.2), value: isAtBottom)
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

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if hasMoreHistory {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 12)
                        .onAppear(perform: onReachTop)
                }
                ForEach(rows) { row in
                    ChatTranscriptRowView(
                        row: row,
                        isExpanded: expandedIDs.contains(row.id),
                        actions: actions
                    )
                    .id(row.id)
                }
                if case .working = agentState {
                    ChatTypingIndicatorView(agentState: agentState)
                        .padding(.top, theme.intraGroupSpacing)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, theme.horizontalMargin)
            .padding(.vertical, 8)
        }
    }
}
