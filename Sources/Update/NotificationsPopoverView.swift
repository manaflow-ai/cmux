import AppKit
import CmuxFoundation
import SwiftUI

/// The titlebar bell / Cmd+I notifications popover, extracted from
/// UpdateTitlebarAccessory.swift (which mounts it from both the accessory
/// controller and the detached-popover path).

private enum NotificationsPopoverMetrics {
    static let defaultWidth: CGFloat = 560
    static let defaultHeight: CGFloat = 760
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 320
    static let maxWidth: CGFloat = 1000
    static let maxHeight: CGFloat = 1200
}

struct NotificationsPopoverView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    let onDismiss: () -> Void

    @AppStorage("cmux.notifications.popover.width")
    private var savedWidth: Double = Double(NotificationsPopoverMetrics.defaultWidth)
    @AppStorage("cmux.notifications.popover.height")
    private var savedHeight: Double = Double(NotificationsPopoverMetrics.defaultHeight)

    // Live size while the user drags the resize handle. We avoid writing through @AppStorage
    // on every mouseDragged event because each write hits UserDefaults and posts
    // UserDefaults.didChangeNotification, which wakes up every observer in the app.
    @State private var liveWidth: CGFloat?
    @State private var liveHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
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
                    .background(Capsule().fill(cmuxAccentColor()))
            }

            NotificationAgentCountsView()

            Spacer()
            Button(action: jumpToLatestUnread) {
                HStack(spacing: 5) {
                    CmuxSystemSymbolImage(systemName: "arrow.down.to.line", pointSize: 10, weight: .semibold)
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
            let tabTitles = AppDelegate.shared?.tabTitlesByTabId() ?? [:]
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(snapshot.enumerated()), id: \.element.id) { index, notification in
                        NotificationPopoverRow(
                            notification: notification,
                            tabTitle: tabTitles[notification.tabId],
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

    private func emptyState(systemImage: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 10) {
            CmuxSystemSymbolImage(systemName: systemImage, pointSize: 30, weight: .light)
                .foregroundColor(.secondary.opacity(0.7))
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

struct NotificationPopoverRow: View, Equatable {
    // Closures excluded from ==; equality is the rendered snapshot only (#2586).
    nonisolated static func == (lhs: NotificationPopoverRow, rhs: NotificationPopoverRow) -> Bool {
        lhs.notification == rhs.notification && lhs.tabTitle == rhs.tabTitle
    }

    let notification: TerminalNotification
    let tabTitle: String?
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
        ZStack(alignment: .trailing) {
            // Primary row action wrapped as a Button so the row participates in the
            // key-view loop: keyboard users can tab to a row and activate it with
            // space/return. Visual styling is owned by rowContent; the button background
            // lets the NSTrackingArea-driven hover tint shine through.
            Button(action: onOpen) {
                rowContent
                    .background(
                        Color.primary.opacity(isHovering ? 0.11 : 0)
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
                .padding(.trailing, 10)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                // Dismissal is exposed through the row Button's accessibility action and the
                // context menu, so hide this hover-only affordance from keyboard focus /
                // VoiceOver when not visible — otherwise Full Keyboard Access can tab to an
                // invisible button.
                .accessibilityHidden(!isHovering)
        }
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

    private var rowContent: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(notification.isRead ? Color.clear : cmuxAccentColor())
                .frame(width: 2.5)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notification.title)
                        .cmuxFont(size: 12.5, weight: .semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                        .cmuxFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 34)
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .cmuxFont(size: 11.5)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let tabTitle, !tabTitle.isEmpty {
                    Text(tabTitle)
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .frame(minHeight: Self.rowHeight)
        .padding(.leading, 4)
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

private struct ResizeGripperRepresentable: NSViewRepresentable {
    let onBegin: () -> (CGFloat, CGFloat)
    let onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> ResizeGripperNSView {
        ResizeGripperNSView()
    }

    func updateNSView(_ nsView: ResizeGripperNSView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

private final class ResizeGripperNSView: NSView {
    var onBegin: () -> (CGFloat, CGFloat) = { (0, 0) }
    var onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void = { _, _, _, _ in }
    var onEnd: () -> Void = {}

    private var pressLocation: NSPoint?
    private var pressStartWidth: CGFloat = 0
    private var pressStartHeight: CGFloat = 0

    private static let diagonalResizeCursor: NSCursor = {
        // AppKit ships a NW–SE diagonal resize cursor for window corners but doesn't expose
        // it publicly. It has lived under this selector for years and is widely used by Mac
        // apps that need a diagonal resize affordance.
        let selector = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        if let method = NSCursor.responds(to: selector) ? NSCursor.perform(selector) : nil,
           let cursor = method.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return NSCursor.crosshair
    }()

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.diagonalResizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        // NSEvent.mouseLocation is screen-coordinate and stable while the popover resizes.
        pressLocation = NSEvent.mouseLocation
        let (w, h) = onBegin()
        pressStartWidth = w
        pressStartHeight = h
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        // Screen-y grows upward; popover should grow as the pointer moves down (toward
        // smaller screen-y), so invert.
        let dy = start.y - current.y
        onDrag(pressStartWidth, pressStartHeight, dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
        onEnd()
    }
}

private struct HoverTrackingRepresentable: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(onChange: onChange)
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class HoverTrackingNSView: NSView {
    var onChange: (Bool) -> Void
    private var trackingArea: NSTrackingArea?
    private var isInside: Bool = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Pass clicks through to the SwiftUI parent (which owns the tap gesture and accessibility
    // action). Tracking areas keep working because they're driven by window mouse-tracking,
    // not by hitTest.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area

        // Sync current pointer state in case the pointer is already inside when the tracking
        // area is (re)installed — happens on first popover open or after layout changes.
        // updateTrackingAreas runs on the main thread, so dispatch synchronously; deferring
        // creates a race where mouseExited can fire before the queued sync-onChange(true) runs,
        // leaving the row stuck in the hovered state.
        if let window, window.isVisible {
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let mouseInView = convert(mouseInWindow, from: nil)
            let nowInside = bounds.contains(mouseInView)
            if nowInside != isInside {
                isInside = nowInside
                onChange(nowInside)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if !isInside {
            isInside = true
            onChange(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isInside {
            isInside = false
            onChange(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isInside {
            isInside = false
            onChange(false)
        }
    }
}
