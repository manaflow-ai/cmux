import Foundation
import SwiftUI

struct SidebarSwipeableRow<Content: View>: View {
    let workspaceId: UUID
    let isUnread: Bool
    let onToggleReadState: () -> Void
    let onDelete: () -> Void

    private let content: Content
    @State private var offset: CGFloat = 0

    init(
        workspaceId: UUID,
        isUnread: Bool,
        onToggleReadState: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.workspaceId = workspaceId
        self.isUnread = isUnread
        self.onToggleReadState = onToggleReadState
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        content
            .background {
                actionBackgrounds
                    .offset(x: -offset)
            }
            .offset(x: offset)
            .clipped()
            .overlay {
                SidebarRowSwipeCaptureView(
                    onOffsetChanged: updateOffset(_:animated:),
                    onCommit: commit(_:)
                )
            }
    }

    @ViewBuilder
    private var actionBackgrounds: some View {
        HStack(spacing: 0) {
            if offset > 0 {
                swipeActionBackground(
                    width: abs(offset),
                    color: Color(nsColor: .systemBlue),
                    systemImage: readStateSystemImage,
                    title: readStateTitle,
                    accessibilityIdentifier: "SidebarWorkspaceReadStateSwipeAction-\(workspaceId.uuidString)"
                )
            }

            Spacer(minLength: 0)

            if offset < 0 {
                swipeActionBackground(
                    width: abs(offset),
                    color: Color(nsColor: .systemRed),
                    systemImage: "trash",
                    title: deleteTitle,
                    accessibilityIdentifier: "SidebarWorkspaceDeleteSwipeAction-\(workspaceId.uuidString)"
                )
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readStateTitle: String {
        isUnread
            ? String(localized: "sidebar.workspaceSwipe.markRead", defaultValue: "Mark as Read")
            : String(localized: "sidebar.workspaceSwipe.markUnread", defaultValue: "Mark as Unread")
    }

    private var readStateSystemImage: String {
        isUnread ? "envelope.open" : "envelope.badge"
    }

    private var deleteTitle: String {
        String(localized: "sidebar.workspaceSwipe.delete", defaultValue: "Delete")
    }

    private func swipeActionBackground(
        width: CGFloat,
        color: Color,
        systemImage: String,
        title: String,
        accessibilityIdentifier: String
    ) -> some View {
        ZStack {
            color

            VStack(spacing: 3) {
                CmuxSystemSymbolImage(systemName: systemImage, pointSize: 15, weight: .semibold)
                    .foregroundColor(.white)

                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .frame(width: 88)
            }
            .frame(width: 96)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func updateOffset(_ nextOffset: CGFloat, animated: Bool) {
        var transaction = Transaction()
        transaction.animation = animated
            ? .spring(response: 0.22, dampingFraction: 0.86)
            : nil
        withTransaction(transaction) {
            offset = nextOffset
        }
    }

    private func commit(_ action: SidebarRowSwipeGestureModel.Action) {
        switch action {
        case .leading:
            onToggleReadState()
        case .trailing:
            onDelete()
        }
    }
}
