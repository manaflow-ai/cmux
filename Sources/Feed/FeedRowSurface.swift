import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import SwiftUI

struct FeedRowSurface: View {
    let snapshot: FeedItemSnapshot
    let actions: FeedRowActions
    let isSelected: Bool
    let isFocusActive: Bool
    let showsDivider: Bool
    @Binding var stopDraft: FeedStopDraft
    let placement: FeedPlacement
    let focusScopeID: UUID
    let onPressSelect: () -> Void
    let onControlFocus: () -> Void
    let onControlAction: () -> Void
    let onControlBlur: () -> Void
    let onActivate: () -> Void

    @State private var isHovered = false
    @State private var stopReplyFocusRequest = 0

    var body: some View {
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
                placement: placement,
                focusScopeID: focusScopeID
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
        .contextMenu {
            Button {
                onActivate()
            } label: {
                Label(
                    String(localized: "feed.contextMenu.openTerminal", defaultValue: "Open Terminal"),
                    systemImage: "terminal"
                )
            }
            Divider()
            Button(role: .destructive) {
                actions.remove(snapshot.id)
            } label: {
                Label(
                    String(localized: "feed.contextMenu.remove", defaultValue: "Remove from Feed"),
                    systemImage: "trash"
                )
            }
            .disabled(snapshot.status.isPending)
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
