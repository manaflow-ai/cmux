import CmuxAgentChat
import SwiftUI
#if os(iOS)
import Combine
import UIKit
#endif

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
    private let bottomContentInset: CGFloat
    private let actions: ChatRowActions
    private let onReachTop: () -> Void
    private let onRetryInitialLoad: () -> Void

    @Environment(\.chatTheme) private var theme

    #if os(iOS)
    @State private var isAtBottom = true
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    #if DEBUG
    @State private var debugScrollGeometry = ChatScrollGeometryDebugSnapshot()
    @State private var lastLoggedDebugScrollGeometry = ChatScrollGeometryDebugSnapshot()
    #endif
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
    ///   - bottomContentInset: Extra scrollable room reserved below the last
    ///     row for an overlaid composer and keyboard.
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
        bottomContentInset: CGFloat = 0,
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
        self.bottomContentInset = bottomContentInset
        self.actions = actions
        self.onReachTop = onReachTop
        self.onRetryInitialLoad = onRetryInitialLoad
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
                .onChange(of: FollowKey(count: rows.count, lastID: rows.last?.id, isWorking: isWorking)) {
                    guard isAtBottom else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                // WhatsApp-style keyboard pinning: when the keyboard shows or
                // hides while the user is at the bottom, re-pin the last rows
                // above the composer instead of letting the rising accessory
                // bar / keyboard cover them. `.defaultScrollAnchor(.bottom)`
                // alone does not re-anchor on the keyboard safe-area change
                // (the composer safeAreaInset absorbs it), so do it explicitly.
                // Guarded by `isAtBottom` so a reading user's scroll is never
                // stolen. Animated to ride the keyboard transition.
                .onReceive(Self.keyboardWillChangePublisher) { _ in
                    guard isAtBottom else { return }
                    withAnimation(.snappy(duration: 0.25)) {
                        if let lastID = rows.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        } else {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // The pill's fade/scale is animated HERE, scoped by
                    // `value: isAtBottom`, so only this overlay animates and the
                    // list layout (LazyVStack) is never re-animated per frame
                    // (that caused a prior 100% CPU scroll-up freeze).
                    Group {
                        if !isAtBottom {
                            ChatScrollToBottomButton {
                                // Scroll to the last row id (reliably scrollable;
                                // the zero-height bottom anchor alone no-ops),
                                // animated so it glides instead of jumping.
                                withAnimation(.snappy(duration: 0.3)) {
                                    if let lastID = rows.last?.id {
                                        proxy.scrollTo(lastID, anchor: .bottom)
                                    } else {
                                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                                    }
                                }
                                // Optimistic immediate hide; the scroll-geometry
                                // reader reconciles within a frame (and correctly
                                // keeps the pill if the scroll genuinely didn't
                                // reach the bottom).
                                isAtBottom = true
                            }
                            .padding(.trailing, 12)
                            .padding(.bottom, 8 + bottomContentInset)
                            .excludedFromKeyboardDismiss()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: isAtBottom)
                }
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

    /// Tail-follow trigger identity; see the onChange comment. Includes
    /// the typing indicator's presence (not a row) so an agent starting
    /// work scrolls the indicator into view for at-bottom readers.
    private struct FollowKey: Equatable {
        let count: Int
        let lastID: String?
        let isWorking: Bool
    }

    private static let bottomAnchorID = "chat.bottom.anchor"

    /// Distance (pt) from the content's end within which the view counts as
    /// "at bottom": absorbs the small gap below the last row (vertical padding
    /// + the 1pt anchor) and lazy-height estimation jitter, while staying well
    /// under one message row so a deliberate scroll-up still shows the pill.
    private static let atBottomThreshold: CGFloat = 40

    #if os(iOS)
    /// Fires on every keyboard frame change (show, hide, height change), used
    /// to re-pin the transcript bottom above the composer.
    private static let keyboardWillChangePublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        .map { _ in () }
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
                // tail-follow, the pill, and keyboard re-pin. At-bottom is no
                // longer derived from this view's visibility (it sits at the
                // composer/keyboard safe-area boundary and under-reported as
                // "visible", desyncing the pill and the keyboard guard);
                // `isAtBottom` now comes from the scroll geometry below.
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
            }
            .scrollTargetLayout()
            .padding(.horizontal, theme.horizontalMargin)
            .padding(.top, 8)
            .padding(.bottom, 8 + bottomContentInset)
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
        #if os(iOS)
        .scrollPosition($scrollPosition)
        // At-bottom is read directly from the scroll geometry (the source of
        // truth), not a sentinel view's visibility. `visibleRect.maxY` is the
        // bottom of the visible content in content coordinates and already
        // accounts for the composer/keyboard safe-area insets, so the distance
        // to the content's end is inset-correct and updates on every scroll,
        // keyboard transition, and content-size change. A forgiving threshold
        // absorbs the small gap below the last row (padding + 1pt anchor) and
        // lazy-height jitter.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
        } action: { _, distanceFromBottom in
            let atBottom = distanceFromBottom <= Self.atBottomThreshold
            if atBottom != isAtBottom { isAtBottom = atBottom }
        }
        #if DEBUG
        .onScrollGeometryChange(for: ChatScrollGeometryDebugSnapshot.self) { geometry in
            ChatScrollGeometryDebugSnapshot(geometry)
        } action: { _, snapshot in
            debugScrollGeometry = snapshot
            if snapshot.differsMeaningfully(from: lastLoggedDebugScrollGeometry) {
                print(snapshot.debugLogLine(isAtBottom: isAtBottom))
                lastLoggedDebugScrollGeometry = snapshot
            }
        }
        .overlay(alignment: .topLeading) {
            ChatScrollGeometryDebugOverlay(
                snapshot: debugScrollGeometry,
                isAtBottom: isAtBottom
            )
            .padding(.top, 8)
            .padding(.leading, 8)
            .allowsHitTesting(false)
        }
        #endif
        #endif
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
