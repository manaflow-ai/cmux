import Foundation
import SwiftUI

struct SidebarSwipeableRow<Content: View>: View {
    let workspaceId: UUID
    let isUnread: Bool
    let isSelected: Bool
    let onToggleReadState: () -> Void
    let onDelete: () -> Void

    private let content: Content
    @State private var offset: CGFloat = 0
    @State private var isInCommitZone = false

    init(
        workspaceId: UUID,
        isUnread: Bool,
        isSelected: Bool,
        onToggleReadState: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.workspaceId = workspaceId
        self.isUnread = isUnread
        self.isSelected = isSelected
        self.onToggleReadState = onToggleReadState
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        ZStack {
            actionFillLayer
            content
                .offset(x: offset)
        }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                SidebarRowSwipeCaptureView(
                    workspaceId: workspaceId,
                    onOffsetChanged: updateOffset(_:animated:isInCommitZone:),
                    onCommit: commit(_:containerWidth:)
                )
            }
    }

    @ViewBuilder
    private var actionFillLayer: some View {
        if let activeAction {
            swipeActionFill(for: activeAction)
        } else {
            Color.clear
                .allowsHitTesting(false)
        }
    }

    private var activeAction: SidebarRowSwipeGestureModel.Action? {
        if offset > 0 { return .leading }
        if offset < 0 { return .trailing }
        return nil
    }

    private var readStateTitle: String {
        isUnread
            ? String(localized: "sidebar.workspaceSwipe.markRead", defaultValue: "Mark as Read")
            : String(localized: "sidebar.workspaceSwipe.markUnread", defaultValue: "Mark as Unread")
    }

    private var readStateSystemImage: String {
        let preferred = isUnread ? "envelope.open.fill" : "envelope.badge.fill"
        let fallback = isUnread ? "envelope.open" : "envelope.badge"
        return RenderableSystemSymbol.isRenderable(preferred) ? preferred : fallback
    }

    private var deleteTitle: String {
        String(localized: "sidebar.workspaceSwipe.delete", defaultValue: "Delete")
    }

    private var deleteSystemImage: String {
        RenderableSystemSymbol.isRenderable("trash.fill") ? "trash.fill" : "trash"
    }

    private var iconRevealWidth: CGFloat {
        min(abs(offset), 96)
    }

    private var iconOpacity: Double {
        let revealedDistance = abs(offset)
        guard revealedDistance >= 16 else { return 0 }
        return min(1, Double((revealedDistance - 16) / 16))
    }

    private func swipeActionFill(for action: SidebarRowSwipeGestureModel.Action) -> some View {
        ZStack(alignment: alignment(for: action)) {
            color(for: action)

            if action == .leading, isSelected {
                Color.black.opacity(0.15)
            }

            if isInCommitZone {
                Color.white.opacity(0.12)
            }

            swipeActionIcon(for: action)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(for: action))
        .accessibilityIdentifier(accessibilityIdentifier(for: action))
        .help(title(for: action))
    }

    private func swipeActionIcon(for action: SidebarRowSwipeGestureModel.Action) -> some View {
        CmuxSystemSymbolImage(systemName: systemImage(for: action), pointSize: 15, weight: .semibold)
            .foregroundColor(.white)
            .scaleEffect(isInCommitZone ? 1.15 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isInCommitZone)
            .opacity(iconOpacity)
            .frame(width: iconRevealWidth)
    }

    private func alignment(for action: SidebarRowSwipeGestureModel.Action) -> Alignment {
        switch action {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    private func color(for action: SidebarRowSwipeGestureModel.Action) -> Color {
        switch action {
        case .leading:
            return Color(nsColor: .systemBlue)
        case .trailing:
            return Color(nsColor: .systemRed)
        }
    }

    private func systemImage(for action: SidebarRowSwipeGestureModel.Action) -> String {
        switch action {
        case .leading:
            return readStateSystemImage
        case .trailing:
            return deleteSystemImage
        }
    }

    private func title(for action: SidebarRowSwipeGestureModel.Action) -> String {
        switch action {
        case .leading:
            return readStateTitle
        case .trailing:
            return deleteTitle
        }
    }

    private func accessibilityIdentifier(for action: SidebarRowSwipeGestureModel.Action) -> String {
        switch action {
        case .leading:
            return "SidebarWorkspaceReadStateSwipeAction-\(workspaceId.uuidString)"
        case .trailing:
            return "SidebarWorkspaceDeleteSwipeAction-\(workspaceId.uuidString)"
        }
    }

    private func updateOffset(_ nextOffset: CGFloat, animated: Bool, isInCommitZone: Bool) {
        var transaction = Transaction()
        transaction.animation = animated
            ? .spring(response: 0.25, dampingFraction: 0.85)
            : nil
        withTransaction(transaction) {
            offset = nextOffset
            self.isInCommitZone = isInCommitZone
        }
    }

    private func commit(_ action: SidebarRowSwipeGestureModel.Action, containerWidth: CGFloat) {
        switch action {
        case .leading:
            onToggleReadState()
        case .trailing:
            commitDelete(containerWidth: containerWidth)
        }
    }

    private func commitDelete(containerWidth: CGFloat) {
        isInCommitZone = false
        if #available(macOS 14.0, *) {
            withAnimation(.easeIn(duration: 0.18), completionCriteria: .logicallyComplete) {
                offset = -containerWidth
            } completion: {
                onDelete()
                updateOffset(0, animated: true, isInCommitZone: false)
            }
        } else {
            onDelete()
            updateOffset(0, animated: true, isInCommitZone: false)
        }
    }
}
