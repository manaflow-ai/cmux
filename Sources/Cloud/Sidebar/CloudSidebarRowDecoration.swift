import SwiftUI

/// Immutable pin and folder-attention indicators around the existing row.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let hasUnreadDescendant: Bool

    func body(content: Content) -> some View {
        HStack(spacing: 4) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
            }
            content
            if hasUnreadDescendant {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .accessibilityLabel(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
            }
        }
    }
}
