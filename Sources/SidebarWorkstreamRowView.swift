import AppKit
import CmuxFoundation
import SwiftUI

/// One top-level workstream row in the sidebar's master list. Tapping it drills
/// into the workstream (the sidebar then shows only that workstream's
/// workspaces). The trailing rollup shows the PR-workspace count and an
/// aggregate unread badge — a portfolio glance independent of how many
/// workspaces are underneath.
///
/// `Equatable` + `.equatable()` skips body re-evaluation when nothing this row
/// draws has changed. Closures are excluded from `==` (the parent recreates
/// them every render and they capture only stable ids), honoring the
/// snapshot-boundary rule: this view holds no store reference.
struct SidebarWorkstreamRowView: View, Equatable {
    nonisolated static func == (lhs: SidebarWorkstreamRowView, rhs: SidebarWorkstreamRowView) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.fontScale == rhs.fontScale
    }

    let snapshot: SidebarWorkstreamRowSnapshot
    let fontScale: CGFloat
    let onDrillIn: () -> Void
    let onRename: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var iconColor: Color {
        if let tintHex = snapshot.tintHex, let nsColor = NSColor(hex: tintHex) {
            return Color(nsColor: nsColor)
        }
        return .secondary
    }

    var body: some View {
        let unreadAccessibilityFormat = snapshot.unreadCount == 1
            ? String(localized: "workstream.unread.a11y.one", defaultValue: "%lld unread")
            : String(localized: "workstream.unread.a11y.other", defaultValue: "%lld unread")
        let workspaceCountAccessibilityFormat = snapshot.workspaceCount == 1
            ? String(localized: "workstream.count.a11y.one", defaultValue: "%lld workspace")
            : String(localized: "workstream.count.a11y.other", defaultValue: "%lld workspaces")

        HStack(spacing: 6) {
            Image(systemName: snapshot.iconSymbol)
                .font(.system(size: 12 * fontScale, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 16 * fontScale, height: 16 * fontScale)
                .accessibilityHidden(true)
            Text(snapshot.name)
                .font(.system(size: 13 * fontScale, weight: .semibold))
                .foregroundStyle(snapshot.containsSelectedWorkspace ? Color.primary : Color.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if snapshot.unreadCount > 0 {
                Text("\(snapshot.unreadCount)")
                    .font(.system(size: 10 * fontScale, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        unreadAccessibilityFormat,
                        snapshot.unreadCount
                    )))
            }
            Text("\(snapshot.workspaceCount)")
                .font(.system(size: 11 * fontScale, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(Text(String.localizedStringWithFormat(
                    workspaceCountAccessibilityFormat,
                    snapshot.workspaceCount
                )))
            Image(systemName: "chevron.right")
                .font(.system(size: 10 * fontScale, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            (isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture { onDrillIn() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(snapshot.name))
        .accessibilityHint(Text(String(
            localized: "workstream.drillIn.a11y",
            defaultValue: "Open this workstream"
        )))
        .accessibilityIdentifier("sidebarWorkstreamRow.\(snapshot.id.uuidString)")
        .contextMenu {
            Button(
                String(localized: "workstream.contextMenu.rename", defaultValue: "Rename Workstream…"),
                action: onRename
            )
            Button(
                String(localized: "workstream.contextMenu.moveUp", defaultValue: "Move Up"),
                action: onMoveUp
            )
            Button(
                String(localized: "workstream.contextMenu.moveDown", defaultValue: "Move Down"),
                action: onMoveDown
            )
            Divider()
            Button(
                String(localized: "workstream.contextMenu.delete", defaultValue: "Delete Workstream"),
                role: .destructive,
                action: onDelete
            )
        }
    }
}
