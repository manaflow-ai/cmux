import CmuxFoundation
import SwiftUI

struct NotificationPopoverRow: View, Equatable {
    // Closures excluded from ==; equality is the rendered snapshot only (#2586).
    nonisolated static func == (lhs: NotificationPopoverRow, rhs: NotificationPopoverRow) -> Bool {
        lhs.notification == rhs.notification && lhs.workspaceTitle == rhs.workspaceTitle
    }

    let notification: TerminalNotification
    let workspaceTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let onToggleRead: () -> Void

    @State private var isHovering: Bool = false

    private static let rowHeight: CGFloat = 56

    var body: some View {
        // Row uses a ZStack so the hover-only clear button is a *sibling* of the row's
        // primary-action Button, not nested in its label. Nested SwiftUI buttons don't
        // produce reliable independent hit targets on macOS — clicks on a nested button
        // can be consumed by the outer button's tap area.
        ZStack(alignment: .topTrailing) {
            // Primary row action wrapped as a Button so the row participates in the
            // key-view loop: keyboard users can tab to a row and activate it with
            // space/return. Visual styling is owned by rowContent; the rounded card
            // background carries the unread tint and the NSTrackingArea-driven hover tint.
            Button(action: onOpen) {
                rowContent
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(rowBackgroundColor)
                    )
            }
            .buttonStyle(.plain)
            // Identifier/action live on the Button itself so XCUITest's
            // `app.buttons["NotificationPopoverRow.<id>"]` query keeps matching. A previous
            // pass put them on the combined outer ZStack, which exposed the row as a
            // container rather than a button to accessibility clients.
            .accessibilityIdentifier("NotificationPopoverRow.\(notification.id.uuidString)")
            // XCUITest's `.click()` isn't always reliable for SwiftUI buttons hosted in an
            // `NSPopover`. Provide an explicit accessibility action so AXPress always routes to onOpen.
            .accessibilityAction { onOpen() }
            // The clear button is hover-only for pointer users; expose dismiss as a row-level
            // accessibility action so VoiceOver / keyboard / assistive tech can dismiss too.
            .accessibilityAction(
                named: Text(String(localized: "notifications.row.clear", defaultValue: "Clear notification"))
            ) {
                onClear()
            }

            clearButton
                .padding(.top, 8)
                .padding(.trailing, 10)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                // Dismissal is exposed through the row Button's accessibility action and the
                // context menu, so hide this hover-only affordance from keyboard focus /
                // VoiceOver when not visible — otherwise Full Keyboard Access can tab to an
                // invisible button.
                .accessibilityHidden(!isHovering)
        }
        // Inset each row so the rounded card reads as a distinct cell with gutters.
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover detection runs through an AppKit NSTrackingArea (HoverTrackingRepresentable)
        // because SwiftUI's `.onHover` / `.onContinuousHover` arbitrate with the row's
        // primary action and miss enter/exit events right after the popover opens and when
        // the pointer crosses between LazyVStack rows.
        .background(
            HoverTrackingRepresentable { hovering in
                if isHovering != hovering { isHovering = hovering }
            }
        )
        .contextMenu {
                Button(String(localized: "notifications.open", defaultValue: "Open")) {
                    onOpen()
                }
                if notification.isRead {
                    Button(String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")) {
                        onToggleRead()
                    }
                } else {
                    Button(String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")) {
                        onToggleRead()
                    }
                }
                Divider()
                Button(String(localized: "notifications.dismiss", defaultValue: "Dismiss"), role: .destructive) {
                    onClear()
                }
            }
    }

    private var hasWorkspaceTitle: Bool {
        guard let workspaceTitle else { return false }
        return !workspaceTitle.isEmpty
    }

    // Unread rows get an accent tint; read rows a very subtle neutral card.
    // Hovering deepens either so the whole card reads as the hover target.
    private var rowBackgroundColor: Color {
        if notification.isRead {
            return Color.primary.opacity(isHovering ? 0.09 : 0.035)
        }
        return cmuxAccentColor().opacity(isHovering ? 0.17 : 0.10)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 10) {
            NotificationIconChip(
                symbolName: NotificationPresentation.symbolName(for: notification),
                isUnread: !notification.isRead
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hasWorkspaceTitle ? (workspaceTitle ?? "") : notification.title)
                        .cmuxFont(size: 12.5, weight: .semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityIdentifier(
                            hasWorkspaceTitle
                                ? "NotificationPopoverRow.\(notification.id.uuidString).workspaceTitle"
                                : "NotificationPopoverRow.\(notification.id.uuidString).title"
                        )
                    Spacer(minLength: 6)
                    if !notification.isRead {
                        Circle()
                            .fill(cmuxAccentColor())
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(NotificationPresentation.relativeTimeString(for: notification.createdAt))
                        .cmuxFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .layoutPriority(2)
                        // Reserve room for the hover-only clear button so the time
                        // doesn't slide under it.
                        .padding(.trailing, isHovering ? 22 : 0)
                }

                if hasWorkspaceTitle {
                    Text(notification.title)
                        .cmuxFont(size: 10.5, weight: .medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .cmuxFont(size: 11.5)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: Self.rowHeight, alignment: .top)
    }

    private var clearButton: some View {
        Button(action: onClear) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.1))
                CmuxSystemSymbolImage(systemName: "xmark", pointSize: 9, weight: .bold)
                    .foregroundColor(.primary.opacity(0.7))
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

/// Leading icon chip shared across the notification surfaces (titlebar popover,
/// in-app page). A rounded tinted square holding an SF Symbol derived from the
/// notification; accent-tinted when unread, neutral when read. Mirrors the
/// menu-bar dropdown's chip so all surfaces read as one design.
struct NotificationIconChip: View {
    let symbolName: String
    let isUnread: Bool
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isUnread ? cmuxAccentColor().opacity(0.18) : Color.primary.opacity(0.08))
            .frame(width: size, height: size)
            .overlay(
                CmuxSystemSymbolImage(systemName: symbolName, pointSize: size * 0.46, weight: .semibold)
                    .foregroundColor(isUnread ? cmuxAccentColor() : .secondary)
            )
            .accessibilityHidden(true)
    }
}

/// Small uppercase section header with a count pill, shown above each
/// `Today / Yesterday / Earlier` group of notifications.
struct NotificationGroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.localizedUppercase)
                .cmuxFont(size: 10.5, weight: .semibold)
                .foregroundColor(.secondary)
            Text("\(count)")
                .cmuxFont(size: 10, weight: .semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
