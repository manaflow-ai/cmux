import AppKit
import Bonsplit
import Combine
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSettingsUI
import CmuxTestSupport
import Observation
import SwiftUI

struct NotificationsPopoverView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let onDismiss: () -> Void
    let onOpenPhoneForwarding: () -> Void

    @AppStorage("cmux.notifications.popover.width")
    private var savedWidth: Double = Double(NotificationsPopoverMetrics.defaultWidth)
    @AppStorage("cmux.notifications.popover.height")
    private var savedHeight: Double = Double(NotificationsPopoverMetrics.defaultHeight)

    // Live size while the user drags the resize handle. We avoid writing through @AppStorage
    // on every mouseDragged event because each write hits UserDefaults and posts
    // UserDefaults.didChangeNotification, which wakes up every observer in the app.
    @State private var liveWidth: CGFloat?
    @State private var liveHeight: CGFloat?
    @State private var loadedWorkspaceTitles: [UUID: String]?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            phoneForwardingEntry
            Divider()
            content
        }
        .frame(width: clampedWidth, height: clampedHeight)
        .animation(nil, value: clampedWidth)
        .animation(nil, value: clampedHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .onAppear { refreshWorkspaceTitles() }
        .onChange(of: notificationStore.notifications.map(\.tabId)) { _, _ in
            refreshWorkspaceTitles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceTitleDidChange)) { notification in
            refreshWorkspaceTitles(ifRelevantTo: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceGroupNameDidChange)) { notification in
            refreshWorkspaceTitles(ifRelevantTo: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceOrderDidChange)) { notification in
            refreshWorkspaceTitles(ifRelevantTo: notification)
        }
    }

    // Cap against the current screen so the popover (and especially the bottom-right resize
    // handle) stays reachable on small displays even if saved defaults came from a larger one.
    private static let screenMargin: CGFloat = 80

    // The popover doesn't take key, so its host (anchor) window remains key. Use that window's
    // screen so multi-monitor setups clamp against the display where the popover actually
    // appears, not whatever NSScreen.main happens to point at.
    private var popoverScreen: NSScreen? {
        NSApp.keyWindow?.screen ?? NSScreen.main
    }

    private var screenMaxWidth: CGFloat {
        let screenWidth = popoverScreen?.visibleFrame.width ?? NotificationsPopoverMetrics.maxWidth
        return max(NotificationsPopoverMetrics.minWidth, screenWidth - Self.screenMargin)
    }

    private var screenMaxHeight: CGFloat {
        let screenHeight = popoverScreen?.visibleFrame.height ?? NotificationsPopoverMetrics.maxHeight
        return max(NotificationsPopoverMetrics.minHeight, screenHeight - Self.screenMargin)
    }

    private var clampedWidth: CGFloat {
        let raw = liveWidth ?? CGFloat(savedWidth)
        let upper = min(NotificationsPopoverMetrics.maxWidth, screenMaxWidth)
        return min(upper, max(NotificationsPopoverMetrics.minWidth, raw))
    }

    private var clampedHeight: CGFloat {
        let raw = liveHeight ?? CGFloat(savedHeight)
        let upper = min(NotificationsPopoverMetrics.maxHeight, screenMaxHeight)
        return min(upper, max(NotificationsPopoverMetrics.minHeight, raw))
    }

    // Invisible bottom-right corner resize region. NSPopover has no native resize chrome and
    // there's no first-class SwiftUI resize API for it. SwiftUI's `DragGesture` reports
    // translations in a local coordinate space that is literally being resized under the
    // cursor as the user drags, which produces dimension oscillation. We use an AppKit
    // representable that tracks `NSEvent.mouseLocation` in stable global screen coordinates.
    private var resizeHandle: some View {
        ResizeGripperRepresentable(
            onBegin: {
                // Always start from the currently displayed (clamped) size so a drag begins
                // at the visible corner even if stored defaults fall outside the bounds.
                (clampedWidth, clampedHeight)
            },
            onDrag: { startW, startH, dx, dy in
                let upperW = min(NotificationsPopoverMetrics.maxWidth, screenMaxWidth)
                let upperH = min(NotificationsPopoverMetrics.maxHeight, screenMaxHeight)
                let newW = min(upperW, max(NotificationsPopoverMetrics.minWidth, startW + dx))
                let newH = min(upperH, max(NotificationsPopoverMetrics.minHeight, startH + dy))
                liveWidth = newW
                liveHeight = newH
            },
            onEnd: {
                // Persist exactly once on mouseUp instead of hammering UserDefaults during drag.
                if let w = liveWidth {
                    savedWidth = Double(w)
                    liveWidth = nil
                }
                if let h = liveHeight {
                    savedHeight = Double(h)
                    liveHeight = nil
                }
            }
        )
        .frame(width: 16, height: 16)
        .accessibilityLabel(Text(String(localized: "notifications.resize", defaultValue: "Resize notifications")))
        .accessibilityHint(Text(String(localized: "notifications.resize.hint", defaultValue: "Drag to resize the notifications popover")))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                .cmuxFont(size: 14, weight: .semibold)
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(cmuxAccent.color))
            }
            Spacer()
            Button(action: jumpToLatestUnread) {
                HStack(spacing: 5) {
                    CmuxSystemSymbolImage(
                        systemName: "arrow.down.to.line",
                        pointSize: 10,
                        weight: .semibold,
                        tint: hasUnreadNotifications ? .primary : .secondary
                    )
                    Text(String(localized: "notifications.jumpToLatest", defaultValue: "Jump to Latest"))
                        .cmuxFont(size: 11)
                    if !jumpToUnreadShortcut.displayString.isEmpty {
                        Text(jumpToUnreadShortcut.displayString)
                            .cmuxFont(size: 10.5, weight: .medium)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                            // The button already exposes the shortcut via .accessibilityValue;
                            // hide this visual chip from VoiceOver so it isn't announced twice.
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(hasUnreadNotifications ? 0.12 : 0.05))
            )
            .foregroundColor(hasUnreadNotifications ? .primary : .secondary)
            .accessibilityIdentifier("notificationsPopover.jumpToLatest")
            .accessibilityValue(jumpToUnreadShortcut.displayString)
            .safeHelp(
                KeyboardShortcutSettings.Action.jumpToUnread.tooltip(
                    String(localized: "notifications.jumpToLatest", defaultValue: "Jump to Latest")
                )
            )
            .disabled(!hasUnreadNotifications)

            Button(action: { notificationStore.clearAll() }) {
                Text(String(localized: "notifications.clearAll", defaultValue: "Clear All"))
                    .cmuxFont(size: 11)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(notificationStore.notificationMenuSnapshot.hasNotifications ? 0.12 : 0.05))
            )
            .foregroundColor(notificationStore.notificationMenuSnapshot.hasNotifications ? .primary : .secondary)
            .accessibilityIdentifier("notificationsPopover.clearAll")
            .disabled(notificationStore.notificationMenuSnapshot.hasNotifications == false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var phoneForwardingEntry: some View {
        Button(action: onOpenPhoneForwarding) {
            HStack(spacing: 8) {
                CmuxSystemSymbolImage(systemName: "iphone", pointSize: 12, weight: .medium, tint: .secondary)
                Text(
                    String(
                        localized: "notifications.forwardToPhone.title",
                        defaultValue: "Forward notifications to my iPhone"
                    )
                )
                .cmuxFont(size: 12, weight: .medium)
                Spacer()
                CmuxSystemSymbolImage(systemName: "chevron.right", pointSize: 9, weight: .semibold, tint: .secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notificationsPopover.phoneForwarding")
        .safeHelp(
            String(
                localized: "notifications.forwardToPhone.subtitle",
                defaultValue: "Send local agent notifications to cmux on your iPhone. Enabled by default; turn this off to stop this Mac from forwarding them."
            )
        )
    }

    @ViewBuilder
    private var content: some View {
        if !notificationStore.notificationMenuSnapshot.hasNotifications {
            emptyState(
                systemImage: "bell.slash",
                title: String(localized: "notifications.empty.title", defaultValue: "No notifications yet"),
                subtitle: String(localized: "notifications.empty.subtitle", defaultValue: "Desktop notifications will appear here.")
            )
        } else if notificationStore.notifications.isEmpty {
            emptyState(
                systemImage: "bell.badge",
                title: notificationStore.notificationMenuSnapshot.stateHintTitle,
                subtitle: nil
            )
        } else {
            // Snapshot the notifications array as an immutable value before the LazyVStack
            // so the row closures don't reach back into the ObservableObject. Reading the
            // store from inside the ForEach builder reintroduces a store dependency below
            // the list boundary, which is the same anti-pattern CLAUDE.md flags for the
            // sidebar/sessions panel (https://github.com/manaflow-ai/cmux/issues/2586).
            let snapshot = notificationStore.notifications
            let lastIndex = snapshot.count - 1
            // One tabId -> title index per render, not an O(tabs) scan per row (#5794).
            let titleSnapshot = loadedWorkspaceTitles ?? currentWorkspaceTitles()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(snapshot.enumerated()), id: \.element.id) { index, notification in
                        NotificationPopoverRow(
                            notification: notification,
                            workspaceTitle: titleSnapshot[notification.tabId],
                            onOpen: { open(notification) },
                            onClear: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    notificationStore.remove(id: notification.id)
                                }
                            },
                            onToggleRead: {
                                if notification.isRead {
                                    notificationStore.markUnread(id: notification.id)
                                } else {
                                    notificationStore.markRead(id: notification.id)
                                    // A user-initiated "Mark as Read" on a pane-scoped
                                    // notification should also clear the pane's focused-read
                                    // indicator so the pane badge disappears. For
                                    // workspace-level notifications (surfaceId == nil), do not
                                    // call clearFocusedReadIndicator — it treats nil as
                                    // "clear any pane indicator on this tab" and would wipe
                                    // an unrelated pane badge.
                                    if let surfaceId = notification.surfaceId {
                                        notificationStore.clearFocusedReadIndicator(
                                            forTabId: notification.tabId,
                                            surfaceId: surfaceId
                                        )
                                    }
                                }
                            }
                        )
                        .equatable()  // snapshot-boundary: skip unchanged rows (#5794)
                        if index < lastIndex {
                            Divider()
                                .opacity(0.4)
                                .padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }

    private func currentWorkspaceTitles() -> [UUID: String] {
        let notificationWorkspaceIds = Set(notificationStore.notifications.map(\.tabId))
        return AppDelegate.shared?.tabTitlesByTabId(for: notificationWorkspaceIds) ?? [:]
    }

    private func refreshWorkspaceTitles(ifRelevantTo notification: Notification? = nil) {
        let notificationWorkspaceIds = Set(notificationStore.notifications.map(\.tabId))
        guard let notification else {
            let nextTitles = currentWorkspaceTitles()
            guard loadedWorkspaceTitles != nextTitles else { return }
            loadedWorkspaceTitles = nextTitles
            return
        }

        guard let manager = notification.object as? TabManager else { return }
        let changedWorkspaceIds: Set<UUID>
        let changedTitles: [UUID: String]
        switch notification.name {
        case .workspaceTitleDidChange:
            guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            changedWorkspaceIds = [workspaceId]
            changedTitles = manager.resolvedWorkspaceDisplayTitle(forWorkspaceId: workspaceId)
                .map { [workspaceId: $0] } ?? [:]
        case .workspaceGroupNameDidChange:
            changedTitles = manager.resolvedWorkspaceDisplayTitles(for: notificationWorkspaceIds)
            changedWorkspaceIds = Set(changedTitles.keys)
        case .workspaceOrderDidChange:
            changedWorkspaceIds = Set(
                notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
            )
            changedTitles = manager.resolvedWorkspaceDisplayTitles(for: changedWorkspaceIds)
        default:
            return
        }

        let relevantIds = changedWorkspaceIds.intersection(notificationWorkspaceIds)
        guard !relevantIds.isEmpty else { return }
        var nextTitles = loadedWorkspaceTitles ?? currentWorkspaceTitles()
        for workspaceId in relevantIds {
            if let title = changedTitles[workspaceId] {
                nextTitles[workspaceId] = title
            } else {
                nextTitles.removeValue(forKey: workspaceId)
            }
        }
        guard loadedWorkspaceTitles != nextTitles else { return }
        loadedWorkspaceTitles = nextTitles
    }

    private func emptyState(systemImage: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 10) {
            CmuxSystemSymbolImage(systemName: systemImage, pointSize: 30, weight: .light, tint: .secondary.opacity(0.7))
            Text(title)
                .cmuxFont(size: 14, weight: .medium)
                .foregroundColor(.primary)
            if let subtitle {
                Text(subtitle)
                    .cmuxFont(size: 12)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }


    private var jumpToUnreadShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notificationMenuSnapshot.hasUnreadNotifications
    }

    private var unreadCount: Int {
        notificationStore.notificationMenuSnapshot.unreadCount
    }

    private func jumpToLatestUnread() {
        DispatchQueue.main.async {
            AppDelegate.shared?.jumpToLatestUnread()
            onDismiss()
        }
    }

    private func open(_ notification: TerminalNotification) {
        // SwiftUI action closures are not guaranteed to run on the main actor.
        // Ensure window focus + tab selection happens on the main thread.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.openTerminalNotification(notification)
            onDismiss()
        }
    }
}
