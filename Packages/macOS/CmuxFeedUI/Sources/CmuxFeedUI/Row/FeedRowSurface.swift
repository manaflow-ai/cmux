public import AppKit
public import CMUXAgentLaunch
public import SwiftUI

/// Hover/selection background wrapper around a ``FeedItemRow`` plus an optional
/// bottom divider.
///
/// ``FeedRowSurface`` owns the per-row hover and stop-reply-focus transient
/// state and the selection/hover background tint, then renders an
/// `.equatable()` ``FeedItemRow`` so an orthogonal store change cannot
/// re-evaluate the row's body. Like the row, it holds only value snapshots and
/// closures (the snapshot-boundary rule) and forwards the two focus seams down
/// to the row's inline reply fields.
public struct FeedRowSurface: View {
    let snapshot: FeedItemSnapshot
    let actions: FeedRowActions
    let isSelected: Bool
    let isFocusActive: Bool
    let showsDivider: Bool
    @Binding var stopDraft: FeedStopDraft
    let onPressSelect: () -> Void
    let onControlFocus: () -> Void
    let onControlAction: () -> Void
    let onControlBlur: () -> Void
    let onActivate: () -> Void
    /// Focus seam forwarded to the row's inline reply fields: ask the app to
    /// move keyboard focus to the Feed sidebar host for a window.
    let moveFocusToFeedHost: @MainActor (NSWindow) -> Bool
    /// Focus seam forwarded to the row's inline reply fields: report whether a
    /// responder still belongs to the Feed focus domain.
    let responderRetainsFeedFocus: (NSResponder) -> Bool

    @State private var isHovered = false
    @State private var stopReplyFocusRequest = 0

    /// Creates a hover/selection surface around a feed row.
    /// - Parameters:
    ///   - snapshot: Immutable projection of the source item.
    ///   - actions: Closure bundle delivering the user's decisions to the app.
    ///   - isSelected: Whether the row is the current selection.
    ///   - isFocusActive: Whether the selection currently holds keyboard focus.
    ///   - showsDivider: Whether to draw a bottom divider under the row.
    ///   - stopDraft: Binding to the in-progress stop-reply text.
    ///   - onPressSelect: Invoked on first press to select the row.
    ///   - onControlFocus: Invoked when an inline control gains focus.
    ///   - onControlAction: Invoked before an inline control acts on the row.
    ///   - onControlBlur: Invoked when an inline control loses focus.
    ///   - onActivate: Invoked on double-tap to activate the row.
    ///   - moveFocusToFeedHost: Focus seam moving keyboard focus to the Feed
    ///     sidebar host for a window.
    ///   - responderRetainsFeedFocus: Focus seam reporting whether a responder
    ///     still belongs to the Feed focus domain.
    public init(
        snapshot: FeedItemSnapshot,
        actions: FeedRowActions,
        isSelected: Bool,
        isFocusActive: Bool,
        showsDivider: Bool,
        stopDraft: Binding<FeedStopDraft>,
        onPressSelect: @escaping () -> Void,
        onControlFocus: @escaping () -> Void,
        onControlAction: @escaping () -> Void,
        onControlBlur: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        moveFocusToFeedHost: @escaping @MainActor (NSWindow) -> Bool,
        responderRetainsFeedFocus: @escaping (NSResponder) -> Bool
    ) {
        self.snapshot = snapshot
        self.actions = actions
        self.isSelected = isSelected
        self.isFocusActive = isFocusActive
        self.showsDivider = showsDivider
        self._stopDraft = stopDraft
        self.onPressSelect = onPressSelect
        self.onControlFocus = onControlFocus
        self.onControlAction = onControlAction
        self.onControlBlur = onControlBlur
        self.onActivate = onActivate
        self.moveFocusToFeedHost = moveFocusToFeedHost
        self.responderRetainsFeedFocus = responderRetainsFeedFocus
    }

    public var body: some View {
        VStack(spacing: 0) {
            FeedItemRow(
                snapshot: snapshot,
                actions: actions,
                isSelected: isFocusActive,
                onPressSelect: onPressSelect,
                onControlFocus: onControlFocus,
                onControlAction: onControlAction,
                onControlBlur: onControlBlur,
                onActivate: onActivate,
                stopDraft: $stopDraft,
                stopDraftValue: stopDraft,
                stopFocusRequest: $stopReplyFocusRequest,
                stopFocusRequestValue: stopReplyFocusRequest,
                moveFocusToFeedHost: moveFocusToFeedHost,
                responderRetainsFeedFocus: responderRetainsFeedFocus
            )
            .equatable()
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackgroundFill)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackgroundFill: Color {
        if isSelected {
            guard isFocusActive else {
                return Color.primary.opacity(0.07)
            }
            if snapshot.status.isPending {
                return tint.opacity(0.14)
            }
            return Color.primary.opacity(0.075)
        }
        if isHovered {
            if snapshot.status.isPending {
                return tint.opacity(0.10)
            }
            return Color.primary.opacity(0.055)
        }
        return .clear
    }

    private var tint: Color {
        switch snapshot.kind {
        case .permissionRequest: return .orange
        case .exitPlan: return .purple
        case .question: return .blue
        default: return snapshot.status.isPending ? .orange : .secondary.opacity(0.8)
        }
    }
}
